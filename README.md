# proot-bwrap

Steam, and every game it launches, inside a container that has no user namespaces.

The Steam client runs its browser helper, its compatibility tools and every game
through [pressure-vessel](https://gitlab.steamos.cloud/steamrt/steam-runtime-tools),
which builds a container with [bubblewrap](https://github.com/containers/bubblewrap).
bubblewrap needs a user namespace or `CAP_SYS_ADMIN`, and a container's default
seccomp profile grants neither, so inside Docker, Kubernetes, Apptainer or any
similar sandbox a stock Steam stops at exactly that step:

```
pressure-vessel-wrap[…]: E: Child process exited with code 1: bwrap: No permissions
to creating new namespace, likely because the kernel does not allow non-privileged
user namespaces.
```

pressure-vessel already looks for a bubblewrap replacement in `$BWRAP` when its own
copy fails. `proot-bwrap` takes that place. It accepts bubblewrap's command line,
materializes the container the arguments describe, and runs the command in it
through [PRoot](https://proot-me.github.io/) or
[fakechroot](https://github.com/dex4er/fakechroot) instead of namespaces. The Steam
Linux Runtime is used exactly as Valve ships it, so native Linux games get the
runtime libraries they were built against, which is what separates this from
deleting the runtime and hoping the host's libraries fit.

Nothing here replaces bubblewrap where bubblewrap works: pressure-vessel tries its
own copy first and reads `$BWRAP` only after that fails.

## Installing

```bash
sudo ./install.sh
```

The script adds Valve's repository through Steam's own launcher package, installs
the Steam client with the 32-bit libraries the client and games need, installs
fakechroot, puts `proot-bwrap` in `/usr/local/bin`, and diverts `/usr/bin/steam`
so that every way of starting Steam names it: the menu entry, a `steam://` link, a
shell. Nothing else to set. `$BWRAP` still wins where a session sets it.

That last part is what keeps Steam from stopping at its own requirements check,
which refuses to start with "Steam now requires user namespaces to be enabled" when
it can find no working bubblewrap.

In the Selkies desktop images
([GLX](https://github.com/selkies-project/docker-selkies-glx-desktop),
[EGL](https://github.com/selkies-project/docker-selkies-egl-desktop)) the layer is:

```dockerfile
ARG PROOT_BWRAP_REF="main"
RUN curl -fsSL "https://raw.githubusercontent.com/selkies-project/proot-bwrap/${PROOT_BWRAP_REF}/install.sh" | sh
```

Those images already ship a PRoot that carries `CAP_SYS_PTRACE`
(`/opt/proot-apps-cap/proot`), which `proot-bwrap` finds on its own when it needs
it.

## How it works

The bubblewrap command line is a description of a container: bind mounts, symbolic
links, generated files, environment edits, and the command to run. `proot-bwrap`
reads that description, builds the tree it describes as a real directory under
`$XDG_RUNTIME_DIR`, and hands the result to one of two executors.

**fakechroot** is the default. An `LD_PRELOAD` library prefixes every path a
dynamically linked program opens, and bind mounts become symbolic links in the tree.
The dynamic loader and the kernel are not rewritten, so what they follow has to
resolve on the host as well: library search paths are given as tree paths, absolute
symlink targets inside the runtime copy are prefixed, per-architecture preload
modules are paired under one `$LIB` path, and the runtime's `ld.so.cache`
regeneration is replaced by a complete `LD_LIBRARY_PATH`. A bind of a host path at
its own name is passed through untranslated, which is what lets `readlink -f` and
`realpath` agree with the kernel. The container runs on the host's glibc in this
mode, which is what pressure-vessel picks anyway whenever the host's is newer than
the runtime's.

**PRoot** takes over where the fakechroot library is missing, and is available
through `PROOT_BWRAP_BACKEND=proot`. Every bind mount becomes a PRoot binding and
the tree is the guest root, which confines paths for every process rather than only
those that go through libc — the right answer for a program that bypasses it. Its
`ptrace` needs a host that allows tracing: `kernel.yama.ptrace_scope` below 2, or
`CAP_SYS_PTRACE`.

fakechroot leads because of the Steam client. Both executors run games, Proton and
the runtime containers, and they cost the same to within a few per cent, but the
client's browser helper is a Chromium that never answers the client's watchdog under
PRoot. Measured on a bare-metal host where all three work: the sign-in window
appears 8 seconds after launch under fakechroot and 18 under real bubblewrap, while
PRoot reaches "Steamwebhelper is not responding" instead.

The tree is named for what the container is, not for when it started, because a Wine
prefix records the container's root as the path behind its `Z:` drive and every later
launch reuses it. That path differs between the executors, so the drive is repointed
at the root of whichever one is running: a prefix built under one stays usable under
the other. This is the only place where the stand-in knows anything about Steam.

Two environment variables steer it, and neither is needed in normal use:
`PROOT_BWRAP_BACKEND` forces `proot` or `fakechroot`, and `PROOT_BWRAP_DEBUG`
prints the executor's command line. `PROOT_BWRAP_PROOT` names a PRoot binary to
use instead of the ones found on the system.

## Proton

Proton runs Windows games through the same containers, so it needs nothing beyond
the above. Steam's own Proton builds are compatibility tools that require the Steam
Linux Runtime app they name; GE-Proton unpacks into
`~/.steam/steam/compatibilitytools.d` and works the same way. Enable Steam Play for
all titles under `Steam > Settings > Compatibility` and pick the tool there.

## Testing

`tests/steam-shim-check.sh` exercises the stand-in the way Steam does: the soldier,
sniper and scout-on-soldier containers, path canonicalization inside them, OpenGL
and Vulkan for both architectures, an X11 client, a native OpenGL benchmark, a
Windows OpenGL program through GE-Proton, and the Steam client's sign-in window.

```bash
tests/steam-shim-check.sh --home ~/steamtest --backend proot --display :96 \
    --games /usr --wgltri tests/wgltri.exe --client /usr/lib/steam/bin_steam.sh
```

`--force` makes pressure-vessel use the stand-in even where its own bubblewrap
works, which is how a host that has user namespaces tests it at all. The Windows
program is built from `tests/wgltri.c` with a MinGW cross compiler:

```bash
x86_64-w64-mingw32-gcc -O2 -o tests/wgltri.exe tests/wgltri.c -lopengl32 -lgdi32 -luser32 -mconsole
```

## What this replaces

Steam in a namespace-less container has been worked around before, and each
workaround gave something up:

- **Patching the runtime's `_v2-entry-point`** to skip pressure-vessel and run the
  game directly against the host's libraries. Proton worked; native Linux games did
  not, because they are built against the runtime and need it. Steam also verifies
  the runtime against its own `mtree` manifest and re-extracts it, which is what the
  "copy the file while Steam is starting" and live-patcher tricks were for.
- **A `(no runtime)` compatibility tool** pointing straight at `proton`, for the same
  reason and with the same limits. Proton runs through the ordinary Steam Linux
  Runtime here, so the extra `compatibilitytool.vdf` and `toolmanifest.vdf` pairs are
  no longer needed.
- **Deleting `/run/host/container-manager` and `/run/systemd/container`**, which makes
  Steam's requirements check believe it is already inside pressure-vessel and skip
  testing bubblewrap. The check passes for real here: it probes with
  `bwrap --bind / / true`, and the stand-in answers it.

`steamdeps` is still worth neutralizing, and the installer does: the client's
dependency check would otherwise drive `apt` through `pkexec` at every start, so
there is also no need to point `pkexec` at `sudo`.

## What it is not

This is a compatibility shim, not a security boundary. The container it builds
confines paths, not privileges: the surrounding container is what isolates the
session, exactly as it is for the browsers those images ship with `--no-sandbox`.
