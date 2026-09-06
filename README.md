# proot-bwrap

Steam, Proton and Wine inside a container that has no user namespaces.

Steam containerizes its browser helper and every game with
[bubblewrap](https://github.com/containers/bubblewrap), which needs a user
namespace or `CAP_SYS_ADMIN`. A container's default seccomp profile grants
neither, so in Docker, Kubernetes or Apptainer the client refuses to start:

```
Steam now requires user namespaces to be enabled.
```

`proot-bwrap` stands in for bubblewrap. It builds the same container without
namespaces, so the Steam Linux Runtime is used exactly as Valve ships it and
native Linux games get the libraries they were built against.

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/selkies-project/proot-bwrap/main/install.sh | sudo sh
```

That installs Steam with the 32-bit libraries it needs, puts `proot-bwrap` in
`/usr/local/bin`, and points Steam's own launcher at it. Start Steam as usual,
from the menu or with `steam`. Nothing else to configure.

In an image, the same line as a `RUN` step is all that is needed. The Selkies
[GLX](https://github.com/selkies-project/docker-selkies-glx-desktop) and
[EGL](https://github.com/selkies-project/docker-selkies-egl-desktop) desktops
already carry it.

## Proton and Wine

Nothing extra to do. Proton runs through the runtime it asks for, and GE-Proton
works from `~/.steam/steam/compatibilitytools.d`. Enable Steam Play for all
titles under `Steam > Settings > Compatibility` to choose a Proton version.

## How it works

Steam's container is described by a bubblewrap command line: bind mounts,
symbolic links, generated files, and the command to run. `proot-bwrap` reads
that description, builds the tree it describes under `$XDG_RUNTIME_DIR`, and
runs the command in it with [fakechroot](https://github.com/dex4er/fakechroot),
which redirects the paths a program opens instead of creating a namespace.
[PRoot](https://proot-me.github.io/), which traces every process rather than
only what goes through libc, runs a program the fakechroot library cannot be
preloaded into.

Real bubblewrap is still preferred: Steam tries its own copy first and only
falls back to this one.

## Notes

- **PRoot has to be a recent build.** Every released one leaves its own loader
  named in `AT_EXECFN`, and the multi-call coreutils of Ubuntu 25.10 and later
  reads that to decide which tool it is, so `cp`, `ls` and `dirname` fail with
  `coreutils: unknown program`. The installer builds one that answers with the
  program's own name; `proot-bwrap` prefers such a build, and says which it
  picked under `PROOT_BWRAP_DEBUG=1`.
- **The Steam client wants fakechroot.** Both runtimes, both architectures,
  games and Proton run under either backend, but the client's browser helper
  only ever answers its watchdog under fakechroot, so that one leads.
  `PROOT_BWRAP_BACKEND=proot` chooses the other anyway.
- **This is not a security boundary.** It confines paths, not privileges; the
  surrounding container is the boundary, as it already is for the browsers
  those images run with `--no-sandbox`.
- `PROOT_BWRAP_DEBUG=1` prints the command that is actually run.

## Testing

`tests/steam-shim-check.sh` exercises the stand-in the way Steam does: the
soldier, sniper and scout-on-soldier containers, OpenGL and Vulkan for both
architectures, an X11 client, a native benchmark, a Windows OpenGL program
through GE-Proton, and the client's sign-in window.

```bash
tests/steam-shim-check.sh --home ~/steamtest --display :96 \
    --games /usr --wgltri tests/wgltri.exe --client /usr/lib/steam/bin_steam.sh
```

`--force` makes Steam use the stand-in even where its own bubblewrap works,
which is how a host with user namespaces tests it at all. The Windows program
is built from `tests/wgltri.c`:

```bash
x86_64-w64-mingw32-gcc -O2 -o tests/wgltri.exe tests/wgltri.c -lopengl32 -lgdi32 -luser32 -mconsole
```
