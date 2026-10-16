# Monaco diff bundle

`package.json` and `package-lock.json` pin the Monaco editor and bundler versions. The generated app resources are checked in so normal Xcode builds do not need Node or network access.

To rebuild the vendored app resources after changing the version, feature list, or language set, run from the repository root:

```sh
scripts/build-monaco-diff.sh
```

The bundle uses Monaco's ESM API, keeps the diff/read-only features, and registers the built-in basic language definitions for syntax coloring. It intentionally omits language-service workers such as TypeScript, CSS, and HTML; this viewer displays diffs and does not need diagnostics or completion. Monaco 0.55.1 provides JSON through its language-service entry rather than a basic tokenizer, so its worker is retained. The other generated worker is the core editor worker. Since WKWebView rejects module workers loaded directly from the app's `file://` URL, the native viewer injects the bundled worker source and Monaco starts each worker from a blob URL. `package.json` pins DOMPurify to 3.4.16, and the webpack alias replaces Monaco's vendored DOMPurify module so the shipped bundle uses the patched version too.

To update Monaco, review its changelog and compatibility notes, change the exact version in `package.json`, refresh the lockfile with `npm install --package-lock-only --prefix scripts/monaco-diff`, then run `scripts/build-monaco-diff.sh`. Review the generated bundle and worker set, `VERSION.txt`, and third-party licenses. Run the CLI/XPC gate and focused workspace-diff UI case to exercise loading from local `WKWebView` resources.
