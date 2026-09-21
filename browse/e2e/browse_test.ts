// End-to-end tests: a real cling-browse server against a real repository,
// driven by a real browser. Runs with deno, no transpilation step and no
// node_modules (deno caches npm:playwright globally; the browsers themselves
// are provisioned by `deno task install-browsers`, which `build.sh e2e` runs
// automatically).

import { chromium } from "playwright"
import { assert, assertEquals } from "@std/assert"

const browseDir = new URL("..", import.meta.url).pathname

async function run(cmd: string, args: string[]) {
    const output = await new Deno.Command(cmd, { args, cwd: browseDir }).output()
    if (!output.success) {
        throw new Error(cmd + " failed: " + new TextDecoder().decode(output.stderr))
    }
}

async function startServer(dir: string) {
    await run("go", ["run", "./cmd/mktestrepo", dir + "/fixture"])
    await run("go", ["build", "-o", dir + "/cling-browse", "./cmd/cling-browse"])
    const proc = new Deno.Command(dir + "/cling-browse", {
        args: ["--repository", dir + "/fixture/repository", "--passphrase-from-stdin"],
        stdin: "piped",
        stdout: "piped",
        stderr: "inherit",
    }).spawn()
    const stdin = proc.stdin.getWriter()
    await stdin.write(new TextEncoder().encode("test"))
    await stdin.close()
    const reader = proc.stdout.getReader()
    let banner = ""
    while (!banner.includes("\n")) {
        const { value, done } = await reader.read()
        if (done) {
            throw new Error("cling-browse exited before printing its URL")
        }
        banner += new TextDecoder().decode(value)
    }
    const url = banner.match(/http:\/\/\S+/)?.[0]
    if (!url) {
        throw new Error("no URL in: " + banner)
    }
    return { proc, reader, url }
}

Deno.test({
    name: "browse e2e",
    // Playwright keeps internal handles open, the sanitizers would report
    // them as leaks even though everything is shut down below.
    sanitizeResources: false,
    sanitizeOps: false,
    fn: async (t) => {
        const dir = await Deno.makeTempDir({ prefix: "cling-browse-e2e-" })
        const server = await startServer(dir)
        const browser = await chromium.launch()
        try {
            const context = await browser.newContext({ acceptDownloads: true })
            const page = await context.newPage()

            await t.step("rejects requests without the token", async () => {
                const origin = new URL(server.url).origin
                const response = await fetch(origin + "/")
                assertEquals(response.status, 403)
                await response.body?.cancel()
            })

            await t.step("shows the repository root", async () => {
                await page.goto(server.url)
                await page.getByText("hello.txt", { exact: true }).waitFor()
                await page.getByText("docs", { exact: true }).waitFor()
            })

            await t.step("expands a directory", async () => {
                await page.getByText("docs", { exact: true }).click()
                await page.getByText("readme.md", { exact: true }).waitFor()
                await page.getByText("deep", { exact: true }).click()
                await page.getByText("x.txt", { exact: true }).waitFor()
            })

            await t.step("downloads a file", async () => {
                const downloadPromise = page.waitForEvent("download")
                await page.locator("a[data-download-path='hello.txt']").click()
                const download = await downloadPromise
                assertEquals(download.suggestedFilename(), "hello.txt")
                const path = await download.path()
                assert(path)
                assertEquals(await Deno.readTextFile(path), "hello from cling-sync")
            })
        } finally {
            await browser.close()
            server.proc.kill("SIGTERM")
            await server.proc.status
            server.reader.releaseLock()
            await Deno.remove(dir, { recursive: true })
        }
    },
})
