import re


def on_page_markdown(markdown, page, **kwargs):
    if page.file.src_path != "index.md":
        return markdown
    # Rewrite markdown links: [text](guides/X.md) -> [text](X.md)
    markdown = re.sub(r'\]\(guides/', '](', markdown)
    # Rewrite mermaid click targets: click id "guides/X.md" -> click id "../X/"
    # MkDocs uses directory URLs (e.g. /dockerfile-productization/) and mermaid
    # resolves clicks relative to the current page (/index.html lives at /).
    markdown = re.sub(
        r'click (\w+) "guides/([^"]+)\.md"',
        r'click \1 "\2/"',
        markdown,
    )
    return markdown
