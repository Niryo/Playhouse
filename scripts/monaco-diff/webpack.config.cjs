const path = require("node:path");
const MonacoWebpackPlugin = require("monaco-editor-webpack-plugin");
const metadata = require("monaco-editor/esm/metadata.js");
const currentDOMPurify = require.resolve("dompurify");

const excludedFeatures = new Set([
  "anchorSelect",
  "codeAction",
  "codelens",
  "colorPicker",
  "comment",
  "cursorUndo",
  "dnd",
  "dropOrPasteInto",
  "documentSymbols",
  "format",
  "gotoError",
  "gotoSymbol",
  "gpu",
  "inPlaceReplace",
  "inlayHints",
  "inlineCompletions",
  "inlineProgress",
  "linkedEditing",
  "parameterHints",
  "referenceSearch",
  "rename",
  "semanticTokens",
  "snippet",
  "suggest"
]);

const syntaxOnlyLanguages = metadata.languages
  .filter(({ label }) => label !== "json")
  .map(({ label }) => ({
  label,
  entry: `vs/basic-languages/${label}/${label}.contribution`
  }));

module.exports = {
  target: "web",
  entry: "./src/diff.js",
  output: {
    path: path.resolve(__dirname, "dist"),
    filename: "diff.bundle.js",
    chunkFilename: "chunks/[name].[contenthash:8].js",
    assetModuleFilename: "assets/[name][ext]",
    publicPath: "auto",
    clean: true
  },
  module: {
    rules: [
      {
        test: /\.css$/i,
        use: ["style-loader", "css-loader"]
      },
      {
        test: /\.ttf$/i,
        type: "asset/resource"
      }
    ]
  },
  resolve: {
    alias: {
      "./dompurify/dompurify.js$": currentDOMPurify
    }
  },
  optimization: {
    splitChunks: false,
    runtimeChunk: false
  },
  plugins: [
    new MonacoWebpackPlugin({
      languages: ["json"],
      customLanguages: syntaxOnlyLanguages,
      features: metadata.features
        .map(({ label }) => label)
        .filter((label) => !excludedFeatures.has(label)),
      filename: "[name].worker.js"
    })
  ],
  stats: "errors-warnings"
};
