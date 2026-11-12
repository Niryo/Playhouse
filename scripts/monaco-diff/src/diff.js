import * as monaco from "monaco-editor/esm/vs/editor/editor.api";

let diffEditor = null;
let originalModel = null;
let modifiedModel = null;
let fileWorkerFactoryConfigured = false;

function configureFileWorkerFactory() {
  if (fileWorkerFactoryConfigured || window.location.protocol !== "file:") return;
  const environment = globalThis.MonacoEnvironment;
  const workerSources = window.playhouseMonacoWorkerSources;
  if (!environment || !workerSources) return;

  // WebKit rejects module workers loaded directly from the app's local file URL.
  // Native code injects the bundled worker source so Monaco can run it from a blob.
  environment.getWorker = (_moduleId, label) => {
    const source = workerSources[label];
    if (typeof source !== "string") {
      throw new Error(`The bundled ${label} worker source is missing.`);
    }
    const workerURL = URL.createObjectURL(new Blob([source], { type: "text/javascript" }));
    return new Worker(workerURL, { name: label, type: "module" });
  };
  fileWorkerFactoryConfigured = true;
}

function defineDiffTheme(theme) {
  const isDark = theme === "vs-dark";
  const themeName = isDark ? "playhouse-vs-dark" : "playhouse-vs";
  monaco.editor.defineTheme(themeName, {
    base: isDark ? "vs-dark" : "vs",
    inherit: true,
    rules: [],
    colors: {
      "diffEditor.insertedLineBackground": isDark ? "#1f3d2a" : "#e6ffed",
      "diffEditor.insertedTextBackground": isDark ? "#2ea04366" : "#acf2bd",
      "diffEditor.removedLineBackground": isDark ? "#4b2529" : "#ffebe9",
      "diffEditor.removedTextBackground": isDark ? "#f8514966" : "#fdb8c0",
      "diffEditorGutter.insertedLineBackground": isDark ? "#2ea04366" : "#acf2bd",
      "diffEditorGutter.removedLineBackground": isDark ? "#f8514966" : "#fdb8c0",
      // Monaco already shows its sliders only while the editor is hovered; match the app's
      // native scrollers with a subdued resting slider that turns opaque while dragged.
      "scrollbarSlider.background": isDark ? "#79797938" : "#64646438",
      "scrollbarSlider.hoverBackground": isDark ? "#79797966" : "#64646466",
      "scrollbarSlider.activeBackground": isDark ? "#bfbfbfb3" : "#000000a6"
    }
  });
  return themeName;
}

function languageFor(path) {
  const lowerPath = path.toLowerCase();
  for (const language of monaco.languages.getLanguages()) {
    if ((language.extensions || []).some((extension) => lowerPath.endsWith(extension.toLowerCase()))) {
      return language.id;
    }
  }
  return "plaintext";
}

function clearModels() {
  if (originalModel) originalModel.dispose();
  if (modifiedModel) modifiedModel.dispose();
  originalModel = null;
  modifiedModel = null;
}

window.playhouseDiff = {
  getLineChangeCount() {
    const lineChanges = diffEditor?.getLineChanges();
    return lineChanges === null || lineChanges === undefined ? null : lineChanges.length;
  },
  setDiff(payload) {
    const editorRoot = document.getElementById("editor");
    const message = document.getElementById("message");
    if (!payload.isText) {
      clearModels();
      if (diffEditor) diffEditor.setModel(null);
      editorRoot.style.display = "none";
      message.textContent = payload.message || "This file can't be shown as a text diff.";
      message.style.display = "block";
      return;
    }

    message.style.display = "none";
    editorRoot.style.display = "block";
    const theme = defineDiffTheme(payload.theme);
    monaco.editor.setTheme(theme);
    configureFileWorkerFactory();

    if (!diffEditor) {
      diffEditor = monaco.editor.createDiffEditor(editorRoot, {
        automaticLayout: true,
        readOnly: true,
        originalEditable: false,
        renderSideBySide: true,
        enableSplitViewResizing: true,
        minimap: { enabled: false },
        scrollBeyondLastLine: false,
        renderIndicators: true,
        diffWordWrap: "on",
        theme
      });
    } else {
      diffEditor.setModel(null);
    }

    clearModels();
    const language = languageFor(payload.path);
    const baseUri = monaco.Uri.parse("inmemory://playhouse/" + encodeURIComponent(payload.path));
    originalModel = monaco.editor.createModel(
      payload.original,
      language,
      baseUri.with({ path: baseUri.path + ".original" })
    );
    modifiedModel = monaco.editor.createModel(
      payload.modified,
      language,
      baseUri.with({ path: baseUri.path + ".modified" })
    );
    diffEditor.setModel({ original: originalModel, modified: modifiedModel });
    diffEditor.layout();
  }
};

window.playhouseDiffReady = true;
