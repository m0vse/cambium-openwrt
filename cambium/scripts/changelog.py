#!/usr/bin/env python3
"""Render the family changelogs (cambium/changelog/*.md).

  changelog.py html CHANGELOG_DIR INDEX_HTML > changelog.html
      the site's changelog page, styled like INDEX_HTML
  changelog.py unreleased CHANGELOG_DIR > notes.md
      every file's "Unreleased" section, for a snapshot's release notes

The files use a small Markdown subset: "#" and "##" headings, paragraphs,
"- " list items (continued by indented lines), **bold**, `code` and
[links](url).
"""

import html
import pathlib
import re
import sys

ORDER = ["common", "sage", "thor", "jaguar", "cheetah"]


def files(directory):
    d = pathlib.Path(directory)
    names = [n for n in ORDER if (d / f"{n}.md").exists()]
    names += sorted(p.stem for p in d.glob("*.md") if p.stem not in names and p.stem != "README")
    return [(n, (d / f"{n}.md").read_text()) for n in names]


def inline(text):
    text = html.escape(text, quote=False)
    text = re.sub(r"`([^`]+)`", r"<code>\1</code>", text)
    text = re.sub(r"\*\*([^*]+)\*\*", r"<strong>\1</strong>", text)
    return re.sub(r"\[([^\]]+)\]\(([^)\s]+)\)", r'<a href="\2">\1</a>', text)


def blocks(markdown):
    """Yield (kind, text) blocks: h1, h2, p, li."""
    kind, lines = None, []
    for raw in markdown.splitlines() + [""]:
        line = raw.rstrip()
        continues = kind in ("p", "li") and line.startswith("  ") and line.strip()
        if kind and (not line.strip() or not (continues or (kind == "p" and not line.startswith(("#", "- "))))):
            yield kind, " ".join(l.strip() for l in lines)
            kind, lines = None, []
        if not line.strip() or continues or (kind == "p"):
            if continues or kind == "p":
                lines.append(line)
            continue
        if line.startswith("## "):
            yield "h2", line[3:]
        elif line.startswith("# "):
            yield "h1", line[2:]
        elif line.startswith("- "):
            kind, lines = "li", [line[2:]]
        else:
            kind, lines = "p", [line]


def slug(family, heading):
    return family + "-" + re.sub(r"[^a-z0-9]+", "-", heading.lower()).strip("-")


def render_html(directory, index_html):
    style = re.search(r"<style>.*?</style>", pathlib.Path(index_html).read_text(), re.S).group(0)
    out, toc = [], []
    for family, text in files(directory):
        title = family.capitalize()
        body, in_list = [], False
        for kind, value in blocks(text):
            if kind != "li" and in_list:
                body.append("</ul>")
                in_list = False
            if kind == "h1":
                title = value.replace(" changelog", "")
            elif kind == "h2":
                body.append(f'<h3 id="{slug(family, value)}">{inline(value)}</h3>')
            elif kind == "p":
                body.append(f'<p class="lead">{inline(value)}</p>')
            elif kind == "li":
                if not in_list:
                    body.append("<ul>")
                    in_list = True
                body.append(f"<li>{inline(value)}</li>")
        if in_list:
            body.append("</ul>")
        toc.append(f'<a href="#{family}">{html.escape(title)}</a>')
        out.append(f'<section id="{family}">\n<h2>{html.escape(title)}</h2>\n' + "\n".join(body) + "\n</section>")
    return f"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Cambium OpenWrt changes</title>
<meta name="description" content="What changed in each Cambium OpenWrt family, snapshot by snapshot.">
{style}
</head>
<body>
<header>
  <div class="wrap">
    <h1><a href="./" style="color:inherit;text-decoration:none">Cambium <span>OpenWrt</span></a></h1>
    <nav>{" ".join(toc)} <a href="./">Back to the guide</a></nav>
  </div>
</header>
<main class="wrap">
<p class="lead">Newest first. Each heading is the snapshot a change first shipped in;
<em>Unreleased</em> changes are on <code>main</code> and ship in the next snapshot.</p>
{chr(10).join(out)}
</main>
</body>
</html>
"""


def render_unreleased(directory):
    parts = []
    for family, text in files(directory):
        title, section, taking = family.capitalize(), [], False
        for kind, value in blocks(text):
            if kind == "h1":
                title = value.replace(" changelog", "")
            elif kind == "h2":
                taking = value.strip().lower() == "unreleased"
            elif taking and kind == "li":
                section.append(f"- {value}")
        if section:
            parts.append(f"### {title}\n\n" + "\n".join(section))
    if not parts:
        return ""
    return "## Changes in this snapshot\n\n" + "\n\n".join(parts) + "\n"


if __name__ == "__main__":
    if len(sys.argv) == 4 and sys.argv[1] == "html":
        sys.stdout.write(render_html(sys.argv[2], sys.argv[3]))
    elif len(sys.argv) == 3 and sys.argv[1] == "unreleased":
        sys.stdout.write(render_unreleased(sys.argv[2]))
    else:
        sys.exit(__doc__)
