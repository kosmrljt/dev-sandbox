Third-party libraries embedded into map/architecture.html so the page works offline.

| File | Library | Version | License |
| --- | --- | --- | --- |
| marked.umd.js | marked (https://marked.js.org) | 18.2.0 | MIT, see LICENSE-marked.txt |
| mermaid.min.js | Mermaid (https://mermaid.js.org) | 11.17.2 | MIT |

mermaid.min.js is about 3.5 MB and is not kept in the repository. setup-root.sh
downloads it into this folder when the image is built (version and checksum are
pinned there). If a file is missing, archdoc.py links the same version from a
CDN instead, and the page then needs internet access.
