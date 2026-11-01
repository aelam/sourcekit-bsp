# Wiki source pages

These pages document the current source tree. Older releases may have different
capabilities. The historical implementation plans elsewhere in `Docs` are not a
current feature checklist.

| Page | Contents |
| --- | --- |
| [Home](Home.md) | Wiki landing page |
| [Getting started](Getting-Started.md) | Build the server and connect an editor |
| [Build, run, test, and debug](Build-Run-Test-Debug.md) | Commands, destinations, filters, and result handling |
| [Indexing and paths](Indexing-and-Paths.md) | SourceKit-LSP preparation and shared build directories |
| [Protocol support](Protocol-Support.md) | Implemented methods, extensions, limitations, and concurrency |
| [Troubleshooting](Troubleshooting.md) | Navigation, connection, destination, and test failures |

`Home.md` and `_Sidebar.md` use GitHub Wiki links. This index uses repository file
links so the pages can also be read before the Wiki is published.

## Publication

As checked on 2026-11-01, the repository has Wiki enabled but no initialized Wiki
Git repository. The Wiki URL redirects to the repository, and the authenticated
Wiki Git endpoint returns `Repository not found`. These files are prepared source
pages; they have not been published to the Wiki.

To initialize it, an owner must create and save the first `Home` page at
[the GitHub Wiki](https://github.com/aelam/sourcekit-bsp/wiki). GitHub exposes the
Wiki Git repository after that step. Then review and publish these pages:

```sh
# Run from the sourcekit-bsp repository root.
bsp_wiki_sources="$PWD/Docs/wiki"
git clone https://github.com/aelam/sourcekit-bsp.wiki.git /tmp/sourcekit-bsp-wiki
cp "$bsp_wiki_sources/Home.md" "$bsp_wiki_sources/_Sidebar.md" \
  "$bsp_wiki_sources/Getting-Started.md" \
  "$bsp_wiki_sources/Build-Run-Test-Debug.md" \
  "$bsp_wiki_sources/Indexing-and-Paths.md" \
  "$bsp_wiki_sources/Protocol-Support.md" \
  "$bsp_wiki_sources/Troubleshooting.md" /tmp/sourcekit-bsp-wiki/
git -C /tmp/sourcekit-bsp-wiki diff
```

Use a fresh checkout path if `/tmp/sourcekit-bsp-wiki` already exists. Review any
existing Wiki content before replacing it. Commit and push the reviewed pages
from that Wiki checkout. Do not publish this `README.md` as a Wiki page.
