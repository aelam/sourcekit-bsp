# Wiki source pages

These pages document the current implementation. Older plans in `Docs` may be outdated.

| Page | Contents |
| --- | --- |
| [Home](Home.md) | Wiki landing page |
| [Getting started](Getting-Started.md) | Build the server and connect an editor |
| [Build, run, test, and debug](Build-Run-Test-Debug.md) | Commands, destinations, filters, and result handling |
| [Indexing and paths](Indexing-and-Paths.md) | SourceKit-LSP preparation and shared build directories |
| [Protocol support](Protocol-Support.md) | Implemented methods, extensions, limitations, and concurrency |
| [Troubleshooting](Troubleshooting.md) | Navigation, connection, destination, and test failures |

This index links to local files; `Home.md` and `_Sidebar.md` use GitHub Wiki links.

## Publication

The Wiki is not initialized; these pages are not published. An owner must first
save a `Home` page in [GitHub Wiki](https://github.com/aelam/sourcekit-bsp/wiki).
Then copy the sources into a fresh Wiki checkout:

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

Use another path if the checkout already exists. Review, commit, and push from
that checkout. Exclude this `README.md` from publication.
