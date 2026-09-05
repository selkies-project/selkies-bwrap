# selkies-bwrap

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
copy fails. `selkies-bwrap` takes that place. It accepts bubblewrap's command line,
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
fakechroot, and puts `selkies-bwrap` in `/usr/local/bin`. Then, in the environment
Steam starts from:

```bash
export BWRAP="/usr/local/bin/selkies-bwrap"
```

In a container image, put that in the image's environment so every way of starting
Steam carries it. In the Selkies desktop images
([GLX](https://github.com/selkies-project/docker-selkies-glx-desktop),
[EGL](https://github.com/selkies-project/docker-selkies-egl-desktop)) the layer is:

```dockerfile
ARG SELKIES_BWRAP_REF="main"
RUN curl -fsSL "https://raw.githubusercontent.com/selkies-project/selkies-bwrap/${SELKIES_BWRAP_REF}/install.sh" | sh
ENV BWRAP="/usr/local/bin/selkies-bwrap"
```

Those images already ship a PRoot that carries `CAP_SYS_PTRACE`
(`/opt/proot-apps-cap/proot`), which `selkies-bwrap` finds on its own when it needs
it.

## How it works

The bubblewrap command line is a description of a container: bind mounts, symbolic
links, generated files, environment edits, and the command to run. `selkies-bwrap`
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
through `SELKIES_BWRAP_BACKEND=proot`. Every bind mount becomes a PRoot binding and
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
`SELKIES_BWRAP_BACKEND` forces `proot` or `fakechroot`, and `SELKIES_BWRAP_DEBUG`
prints the executor's command line. `SELKIES_BWRAP_PROOT` names a PRoot binary to
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

## What it is not

This is a compatibility shim, not a security boundary. The container it builds
confines paths, not privileges: the surrounding container is what isolates the
session, exactly as it is for the browsers those images ship with `--no-sandbox`.
