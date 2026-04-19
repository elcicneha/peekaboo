---
title: Peekaboo Preview
author: Peekaboo
date: 2026-04-19
tags: [demo, reference]
description: Every feature Peekaboo renders, in one file. Press Space to preview.
---

# Peekaboo Preview

A single file that exercises every feature Peekaboo's Markdown pipeline renders today. Press <kbd>Space</kbd> on this file in Finder to see it, then flip between **Preview** and **Code** using the pill at the top, and toggle **word wrap** with the floating button in the corner.

> Every block below is something Peekaboo will render. If you add a new feature to the renderer, extend this file so people can try it.

---

## Table of contents

- [Headings](#headings)
- [Text formatting](#text-formatting)
- [Lists](#lists)
- [Task lists](#task-lists)
- [Links](#links)
- [Images](#images)
- [Code blocks](#code-blocks)
- [Tables](#tables)
- [Blockquotes](#blockquotes)
- [Horizontal rules](#horizontal-rules)
- [Inline HTML](#inline-html)
- [Smart punctuation](#smart-punctuation)
- [Front matter](#front-matter)

---

## Headings

All six levels, each with an auto-generated anchor you can link to from elsewhere in the document (see the table of contents above).

# Heading 1
## Heading 2
### Heading 3
#### Heading 4
##### Heading 5
###### Heading 6

---

## Text formatting

*italic* and _also italic_
**bold** and __also bold__
***bold italic*** and ___also bold italic___
~~strikethrough~~
`inline code`

A hard line break follows this sentence.<br>
And we're on the next line.

---

## Lists

Unordered, with nesting:

- Espresso
- Cortado
  - Single shot
  - Double shot
    - With oat milk
- Filter

Ordered:

1. First
2. Second
3. Third

---

## Task lists

- [x] Ship view-based preview
- [x] Wire up the VS Code theme
- [x] Add Markdown support
- [ ] Add your feature next

---

## Links

- Inline: [Peekaboo on GitHub](https://github.com/)
- With hover title: [Hover me](https://example.com "I'm a title")
- Autolink: <https://example.com>
- Email: <mailto:hello@example.com>
- In-document anchor: [jump to Code blocks](#code-blocks)
- Reference-style: [the spec][cm]

[cm]: https://commonmark.org "CommonMark"

---

## Images

Remote image (resolved directly):

![placeholder](https://images.agoramedia.com/wte3.0/gcms/When-Do-Babies-Play-Peek-a-Boo-722x406.jpg?text=Peekaboo)

Relative images next to this file are inlined as data URIs — drop an image beside `example.md` and reference it with `![alt](./your-image.png)`. PNG, JPEG, GIF, SVG, WebP, and ICO all work, up to ~2 MB.

---

## Code blocks

Every fenced block is highlighted with your active VS Code (or Antigravity) theme. Change themes in your editor, hit **Refresh** in the Peekaboo app, and previews pick up the new colors.

```swift
// Swift
struct Greeter {
    let name: String
    func greet() -> String {
        "Hello, \(name)!"
    }
}
```

```python
# Python
def fib(n: int) -> list[int]:
    a, b, out = 0, 1, []
    for _ in range(n):
        out.append(a)
        a, b = b, a + b
    return out
```

```ts
// TypeScript
type Result<T, E> = { ok: true; value: T } | { ok: false; error: E }

const parse = (input: string): Result<number, string> =>
  Number.isNaN(+input)
    ? { ok: false, error: `not a number: ${input}` }
    : { ok: true, value: +input }
```

```rust
// Rust
fn main() {
    let nums: Vec<i32> = (1..=5).map(|n| n * n).collect();
    println!("{:?}", nums);
}
```

```go
// Go
package main

import "fmt"

func main() {
    for i, v := range []string{"peek", "a", "boo"} {
        fmt.Printf("%d: %s\n", i, v)
    }
}
```

```json
{
  "name": "peekaboo",
  "features": ["syntax highlight", "markdown", "themes"],
  "version": 1.1
}
```

```sh
# Shell
for f in *.md; do
  echo "found: $f"
done
```

```sql
-- SQL
SELECT name, COUNT(*) AS hits
FROM page_views
WHERE day >= CURRENT_DATE - INTERVAL '7 days'
GROUP BY name
ORDER BY hits DESC
LIMIT 10;
```

```html
<!-- HTML -->
<section class="hero">
  <h1>Hello</h1>
  <p>Hi from Peekaboo.</p>
</section>
```

```css
/* CSS */
.hero {
  background: linear-gradient(135deg, #4f46e5, #ec4899);
  color: white;
  padding: 2rem;
}
```

```yaml
# YAML
name: peekaboo
targets:
  - host
  - extension
  - shared-framework
```

```diff
  keep this line
- remove this line
+ add this line
```

A block with no language falls back cleanly:

```
plain text
no grammar, no colors — just the theme's background and foreground
```

---

## Tables

Basic:

| Feature          | Renders? |
|------------------|:--------:|
| Headings         | ✅       |
| Code blocks      | ✅       |
| Tables           | ✅       |
| Strikethrough    | ✅       |
| Task lists       | ✅       |

Aligned columns with rich cell content:

| Left                | Centered       |         Right |
|:--------------------|:--------------:|--------------:|
| `inline code`       | **bold**       |           100 |
| [a link](#)         | *italic*       |         1,000 |
| ~~strikethrough~~   | H<sub>2</sub>O |        10,000 |

---

## Blockquotes

> A single-line quote.

> A multi-line quote
> that wraps across two lines
> and keeps its indentation together.

> Quotes can nest:
>
> > Second level.
> >
> > > Third level.

---

## Horizontal rules

Three forms — all render as the same `<hr>`:

---

***

___

---

## Inline HTML

Peekaboo passes HTML through, so these all work inline:

Press <kbd>⌘</kbd> + <kbd>Shift</kbd> + <kbd>P</kbd> to open the command palette.

Water is H<sub>2</sub>O and Einstein wrote E = mc<sup>2</sup>.

You can <mark>highlight</mark> a phrase, define an <abbr title="HyperText Markup Language">HTML</abbr> abbreviation, or drop a hard<br>line break.

A collapsible section:

<details>
<summary>Click to expand</summary>

Inside a `<details>` block you can keep using markdown — **bold**, `code`, and lists all work:

- one
- two
- three

</details>

---

## Smart punctuation

Peekaboo turns straight punctuation into typographic equivalents:

- `"quotes"` become “quotes”
- `'apostrophes'` become ‘apostrophes’
- `---` in prose becomes an em-dash — like this
- `--` becomes an en-dash – like this
- `...` becomes an ellipsis…

---

## Front matter

The YAML block at the very top of this file (`title`, `author`, `date`, `tags`, `description`) is stripped before rendering, so it doesn't show up as a stray heading or horizontal rule. TOML (`+++`) and JSON (`;;;`) front matter are stripped the same way. Switch to the **Code** tab to see the raw source including the front matter.

---

## Try it

1. Press <kbd>Space</kbd> in Finder with this file selected.
2. Toggle **Preview ↔ Code** using the pill at the top.
3. Turn on **word wrap** with the floating button in the code view.
4. Open the Peekaboo app and switch your IDE theme — hit **Refresh** and the next preview repaints with the new colors.
