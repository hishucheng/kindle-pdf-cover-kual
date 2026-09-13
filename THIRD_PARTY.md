# Third-party runtime

The bundled `runtime/armv7` and `runtime/kindlehf` files were extracted from the Kindle builds of KOReader 2026.07.1 (armv7 / kindlehf platform, respectively) for the sole purpose of rendering the first PDF page.

Exact upstream revision used for provenance:

- KOReader tag: `v2026.07.1`
- KOReader commit: `9192014d8bd82a91dc1012473be0f238dedfdb54`
- Tag object: `20e58d24588646500ee6c3d2bbcaa5d67b2be580`

Upstream projects and licenses:

- KOReader: https://github.com/koreader/koreader (AGPL-3.0)
- MuPDF: https://mupdf.com/ and https://github.com/ArtifexSoftware/mupdf (AGPL-3.0)
- LuaJIT: https://luajit.org/ (MIT)
- KOReader toolchains and third-party build definitions: https://github.com/koreader/koxtoolchain

The complete corresponding source must remain available whenever the bundled binaries are distributed. The top-level `LICENSE` contains the AGPL-3.0 text shipped with KOReader.
