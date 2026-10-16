#!/usr/bin/env python3

import json
import shutil
import sys
from pathlib import Path


def copy_tree(source: Path, target: Path) -> None:
    for child in source.iterdir():
        destination = target / child.name
        if child.is_dir():
            shutil.copytree(child, destination, dirs_exist_ok=True)
        else:
            shutil.copy2(child, destination)


def main() -> None:
    if len(sys.argv) != 4:
        raise SystemExit("usage: sync-assets.py <webpack-dist> <Monaco-resources> <monaco-editor-package>")

    dist = Path(sys.argv[1]).resolve()
    resources = Path(sys.argv[2]).resolve()
    package = Path(sys.argv[3]).resolve()
    dompurify_package = package.parent / "dompurify"
    repository_root = Path(__file__).resolve().parents[2]
    expected_resources = (repository_root / "StationAI/Resources/Monaco").resolve()
    if resources != expected_resources or resources.name != "Monaco":
        raise SystemExit(f"Refusing to replace unexpected Monaco resources directory: {resources}")
    if not (dist / "diff.bundle.js").is_file():
        raise SystemExit(f"Missing optimized Monaco bundle in {dist}")
    if not (package / "LICENSE").is_file() or not (package / "ThirdPartyNotices.txt").is_file():
        raise SystemExit(f"Missing Monaco license notices in {package}")
    if not all((dompurify_package / name).is_file() for name in ("LICENSE", "LICENSE-MPL")):
        raise SystemExit(f"Missing DOMPurify license notices in {dompurify_package}")

    package_metadata = json.loads((package / "package.json").read_text(encoding="utf-8"))
    version = package_metadata["version"]
    tool_metadata = json.loads((Path(__file__).parent / "package.json").read_text(encoding="utf-8"))
    dompurify_version = tool_metadata["dependencies"]["dompurify"]
    resources.mkdir(parents=True, exist_ok=True)
    for child in resources.iterdir():
        if child.name == "index.html":
            continue
        if child.is_dir():
            shutil.rmtree(child)
        else:
            child.unlink()

    copy_tree(dist, resources)
    shutil.copy2(package / "LICENSE", resources / "LICENSE")
    shutil.copy2(package / "ThirdPartyNotices.txt", resources / "ThirdPartyNotices.txt")
    shutil.copy2(dompurify_package / "LICENSE", resources / "DOMPurify-LICENSE")
    shutil.copy2(dompurify_package / "LICENSE-MPL", resources / "DOMPurify-LICENSE-MPL")
    with (resources / "ThirdPartyNotices.txt").open("a", encoding="utf-8") as notices:
        notices.write(
            "\n\n%% DOMPurify " + dompurify_version + "\n"
            "=========================================\n"
            "Copyright Cure53 and other contributors.\n"
            "Available under Apache-2.0 or MPL-2.0; see DOMPurify-LICENSE and "
            "DOMPurify-LICENSE-MPL in this resource directory.\n"
        )
    (resources / "VERSION.txt").write_text(
        f"Monaco Editor {version}\n"
        "Integration: ESM/Webpack custom diff bundle\n"
        f"DOMPurify override: {dompurify_version}\n"
        "Language support: syntax definitions only; language-service workers omitted\n",
        encoding="utf-8",
    )
    print(f"Updated optimized Monaco app resources from monaco-editor {version}: {resources}")


if __name__ == "__main__":
    main()
