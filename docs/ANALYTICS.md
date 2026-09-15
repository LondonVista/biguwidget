# Analytics (GitHub Pages)

Site: https://londonvista.github.io/biguwidget/

No cookies until you add an ID. The landing page will then send **page views only** (no in-app tracking).

## Umami (recommended, free cloud)

1. Sign up at https://cloud.umami.is
2. Add website:
   - Name: `BigUwidget`
   - Domain: `londonvista.github.io`
3. Copy the **Website ID**
4. In `docs/index.html` set:

```js
window.BIGU_UMAMI_WEBSITE_ID = "paste-id-here";
```

5. Optional: add the same domain **or** a second site for `birch-juniper-cinder-stone.grok.me` and paste that script on the grok.me page too (most of your traffic is there).

Dashboard: https://cloud.umami.is

## Plausible (polished, usually paid)

1. Sign up at https://plausible.io
2. Add `londonvista.github.io`
3. In `docs/index.html` set:

```js
window.BIGU_PLAUSIBLE_DOMAIN = "londonvista.github.io";
```

Do **not** enable both unless you want double-counting.

## What this is not

- Not Google Analytics
- Not silent tracking inside the Mac/Linux/Windows app
- Does not show who downloaded a zip (GitHub still only has download counts)
