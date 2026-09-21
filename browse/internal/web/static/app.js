"use strict"

// The apps inject no page scripts of their own: iOS/macOS expose a WebKit
// message handler (postMessage already returns a promise) and Android a
// synchronous Java object, and both are adapted to the same window.__cling
// contract here.
if (window.webkit?.messageHandlers?.cling && !window.__cling) {
    window.__cling = {
        request: (url) => window.webkit.messageHandlers.cling.postMessage({ kind: "request", url: url }),
        download: (path) => {
            window.webkit.messageHandlers.cling.postMessage({ kind: "download", path: path })
        },
    }
}

if (window.__clingAndroid && !window.__cling) {
    window.__cling = {
        request: (url) =>
            Promise.resolve().then(() => {
                const result = JSON.parse(window.__clingAndroid.request(url))
                if (result.error) {
                    throw new Error(result.error)
                }
                return result.body
            }),
        download: (path) => window.__clingAndroid.download(path),
    }
}

// The one unified transport: the adapters above in the embedded apps, fetch
// in a normal browser. Error responses become rejections in every transport;
// their text must never be treated as HTML.
async function request(path, params) {
    const query = new URLSearchParams(params).toString()
    const url = query ? path + "?" + query : path
    if (window.__cling) {
        return await window.__cling.request(url)
    }
    const response = await fetch(url)
    const text = await response.text()
    if (!response.ok) {
        throw new Error(text)
    }
    return text
}

// The "toggle" event does not bubble, so listen in the capture phase.
document.addEventListener(
    "toggle",
    async (event) => {
        const details = event.target
        if (!(details instanceof HTMLDetailsElement) || !details.open) {
            return
        }
        if (details.dataset.loaded) {
            return
        }
        details.dataset.loaded = "1"
        let html = null
        let failure = null
        try {
            html = await request("dir", { path: details.dataset.path })
        } catch (error) {
            failure = error
        }
        while (details.children.length > 1) {
            details.removeChild(details.lastChild)
        }
        if (failure !== null) {
            // Error text may echo request input, so it must be rendered as
            // text, never parsed as HTML. Clearing "loaded" allows a retry.
            const paragraph = document.createElement("p")
            paragraph.className = "error"
            paragraph.textContent = String(failure)
            details.append(paragraph)
            delete details.dataset.loaded
            return
        }
        details.insertAdjacentHTML("beforeend", html)
    },
    true,
)

// In the embedded apps downloads are handled natively so file bytes never
// cross the JS bridge. In a normal browser the link just navigates.
document.addEventListener("click", (event) => {
    const link = event.target.closest("a[data-download-path]")
    if (!link || !window.__cling) {
        return
    }
    event.preventDefault()
    window.__cling.download(link.dataset.downloadPath)
})
