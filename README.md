# kzen

Office and robotic-process automation, driven from your browser.

### Download
Latest release: https://github.com/alexoooo/kzen/releases/latest

- `kzen-<version>.zip` — Windows, self-contained (bundled JDK, no Java install needed)
- `kzen-<version>-jars.zip` — any OS, requires Java 26

### Install
- Download the archive for your operating system
- Extract zip file (e.g. C:\kzen)

### Run
- Windows: double-click `kzen.bat` (or run `kzen-cmd.bat` to keep a console with the logs)
- Other: run `java -jar kzen-<version>.jar` from the extracted folder
- Wait to load...
- Browser will open at: http://localhost:8080

### Notes
- Artifact downloads (launcher and project archives) validate TLS certificates with the JVM's
  default trust store. In environments with TLS-intercepting proxies (corporate MITM), supply your
  own trust store via `-Djavax.net.ssl.trustStore=<path>` when launching.

### Screenshots
See: https://github.com/alexoooo/kzen-shell/wiki/Screenshots

Example:
![image](https://user-images.githubusercontent.com/4985552/142746508-a91844fd-6de4-4683-8ccc-0292e352eb1a.png)

### Development
This repository is a Gradle composite-build umbrella with no source of its own — it `includeBuild`s
the sibling repositories, which must be cloned alongside it:

- [kzen-lib](https://github.com/alexoooo/kzen-lib) — context management core
- [kzen-auto](https://github.com/alexoooo/kzen-auto) — automation engine and web UI
- [kzen-project](https://github.com/alexoooo/kzen-project) — project template you extend
- [kzen-launcher](https://github.com/alexoooo/kzen-launcher) — project selection UI
- [kzen-shell](https://github.com/alexoooo/kzen-shell) — desktop shell and entry point

See [AGENTS.md](AGENTS.md) for the build layout, [docs/CODING_STANDARDS.md](docs/CODING_STANDARDS.md)
and [docs/RELEASING.md](docs/RELEASING.md).
