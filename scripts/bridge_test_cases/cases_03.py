from test_bridge_support import *
from test_bridge_support import __file__

class BridgeTestCases03:
    # case-contract: test_standalone_chat_claude_fallback_classifier | When a standalone chat uses Claude, a missed page signal invokes the Haiku helper at low effort; a malformed result is rejected and retried, an unrelated later question and its assistant reply move to a new titled page, the UI keeps page evaluation visually quiet without blocking the primary answer, updates the transcript separator when classification completes, and holds a following send until the decision resolves, and appends the related follow-up in chronological order. The Claude-specific model and effort arguments are verified through the real CLI/XPC path. An explicit page start during a pending fallback cancels its stale result, keeps the missed turn on its original page, and clears the warning. If all helper results are invalid, the pending decision remains durable, blocks the next provider send, and retries after the helper recovers; the UI keeps the unresolved state visually quiet and sends successfully once recovery completes.
    def test_standalone_chat_claude_fallback_classifier(self):
        self.assert_success(self.call_cli("settings", "set-default-provider", "claude")[0])
        self.assert_success(self.call_cli("settings", "clear-parent")[0])
        executable = self.data_directory / "claude-fixture-chat-page-fallback"
        copy_file(Path(__file__).resolve().parent / "fixtures" / "claude-code-fixture.py", executable)
        executable.chmod(0o755)
        (self.data_directory / ".playhouse-claude-fixture-owner").write_text(
            "Playhouse test owns this Claude Code protocol fixture (v1).\n", encoding="utf-8"
        )
        environment = {"PLAYHOUSE_E2E_CLAUDE_EXECUTABLE": str(executable)}
        chat = self.assert_success(self.call_cli("chat", "open", extra_environment=environment)[0])
        chat_id = chat["id"]
        first = self.assert_success(self.call_cli("chat", "page", "new", "--title", "General chat", extra_environment=environment)[0])["page"]

        def wait_for_page(title):
            deadline = time.monotonic() + 30
            status = self.assert_success(self.call_cli("chat", "status", extra_environment=environment)[0])
            while time.monotonic() < deadline:
                if not status["missedPreviousPageSignal"] and status["activePage"]["title"] == title:
                    return status
                time.sleep(0.1)
                status = self.assert_success(self.call_cli("chat", "status", extra_environment=environment)[0])
            self.fail(f"Claude fallback did not resolve the active page as {title!r}: {status!r}")

        classifier_hold = Path(str(executable) + ".hold-classifier")
        classifier_active = Path(str(executable) + ".classifier-active")
        classifier_release = Path(str(executable) + ".classifier-release")
        classifier_active.unlink(missing_ok=True)
        classifier_release.unlink(missing_ok=True)
        classifier_hold.touch()
        self.assert_success(self.call_cli(
            "conversation", "send", chat_id, "--message", "Tell me about volcanoes", extra_environment=environment
        )[0])
        classifier_command = ("chat", "status")
        classifier_process = self.start_cli(*classifier_command, extra_environment=environment)
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline and not classifier_active.exists():
            time.sleep(0.02)
        self.assertTrue(classifier_active.exists(), "Claude send should return while Haiku classification is held in the background.")
        queued_turn = ("conversation", "send", chat_id, "--message", "Tell me about Saturn's rings")
        queued_process = self.start_cli(*queued_turn, extra_environment=environment)
        try:
            time.sleep(0.2)
            self.assertIsNone(queued_process.poll(), "Claude should hold a subsequent turn behind pending page resolution.")
            pending_history = json.loads(Path(str(executable) + ".history").read_text(encoding="utf-8"))
            self.assertFalse(
                any((turn.get("userText") or "").startswith("Tell me about Saturn's rings") for turn in pending_history.get("turns", [])),
                "A queued Claude turn must not reach its provider before the page decision is persisted.",
            )
        finally:
            classifier_release.write_text("Release classifier.\n", encoding="utf-8")
        classifier_response, _ = self.finish_cli(classifier_process, classifier_command)
        classifier_status = self.assert_success(classifier_response)
        self.assertFalse(classifier_status["missedPreviousPageSignal"])
        queued_result, _ = self.finish_cli(queued_process, queued_turn)
        self.assert_success(queued_result)
        second_status = wait_for_page("Saturn Rings")
        self.assertNotEqual(second_status["activePage"]["id"], first["id"], "An unrelated turn should start a Claude-classified page.")
        self.assertEqual(self.assert_success(self.call_cli("chat", "page", "list", extra_environment=environment)[0])["pages"][1]["title"], "Volcanoes")
        self.assert_success(self.call_cli(
            "conversation", "send", chat_id, "--message", "One more thought about Saturn", extra_environment=environment
        )[0])
        third_status = wait_for_page("Saturn Rings")
        self.assertEqual(third_status["activePage"]["id"], second_status["activePage"]["id"], "The related follow-up should continue the Saturn page.")
        first_messages = self.assert_success(self.call_cli("chat", "page", "read", first["id"], extra_environment=environment)[0])["messages"]
        second_messages = self.assert_success(self.call_cli("chat", "page", "read", third_status["activePage"]["id"], extra_environment=environment)[0])["messages"]
        self.assertEqual(
            [message["text"] for message in second_messages],
            ["Tell me about Saturn's rings", "OK.", "One more thought about Saturn", "OK."],
            "A later appended turn must follow messages moved by the Claude fallback.",
        )
        self.assertTrue(any(message["text"] == "Tell me about volcanoes" for message in first_messages))
        self.assertTrue(any(message["text"] == "Tell me about Saturn's rings" for message in second_messages))
        self.assertFalse(any(message["text"] == "Tell me about Saturn's rings" for message in first_messages))
        history = json.loads(Path(str(executable) + ".history").read_text(encoding="utf-8"))
        classification_turns = [turn for turn in history["turns"] if (turn.get("userText") or "").startswith("Classify the latest user message for Playhouse's continuous chat page index.")]
        self.assertEqual(len(classification_turns), 4, "The fallback should retry one malformed result and classify a later follow-up.")
        for turn in classification_turns:
            self.assertEqual(turn["effort"], "low", "Claude fallback must set low effort.")
            self.assertEqual(turn["arguments"][turn["arguments"].index("--model") + 1], "haiku", "Claude fallback must use Haiku.")

        classifier_hold.touch()
        self.assert_success(self.call_cli(
            "conversation", "send", chat_id, "--message", "Tell me about Neptune", extra_environment=environment
        )[0])
        classifier_process = self.start_cli("chat", "status", extra_environment=environment)
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline and not classifier_active.exists():
            time.sleep(0.02)
        self.assertTrue(classifier_active.exists(), "The Claude fallback should be pending when the explicit page starts.")
        explicit_page = self.assert_success(self.call_cli(
            "chat", "page", "new", "--title", "Explicit topic", extra_environment=environment
        )[0])["page"]
        self.assertEqual(self.assert_success(self.call_cli("chat", "page", "list", extra_environment=environment)[0])["pages"][0]["id"], explicit_page["id"])
        classifier_release.write_text("Release classifier.\n", encoding="utf-8")
        classifier_response, _ = self.finish_cli(classifier_process, ("chat", "status"))
        self.assert_success(classifier_response)
        final_status = self.assert_success(self.call_cli("chat", "status", extra_environment=environment)[0])
        self.assertFalse(final_status["missedPreviousPageSignal"], "Explicit page creation should clear the missed-signal warning.")
        self.assertEqual(final_status["activePage"]["id"], explicit_page["id"])
        self.assertEqual(final_status["activePage"]["title"], "Explicit topic")
        self.assertEqual(self.assert_success(self.call_cli("chat", "page", "read", explicit_page["id"], extra_environment=environment)[0])["messages"], [])
        old_page_messages = self.assert_success(self.call_cli("chat", "page", "read", second_status["activePage"]["id"], extra_environment=environment)[0])["messages"]
        self.assertTrue(any(message["text"] == "Tell me about Neptune" for message in old_page_messages))
        self.assertTrue(any(message["role"] == "assistant" and message["text"] == "OK." for message in old_page_messages))

        classifier_failure = Path(str(executable) + ".fail-classifier")
        classifier_failure.touch()
        self.assert_success(self.call_cli(
            "conversation", "send", chat_id, "--message", "Tell me about Mars", extra_environment=environment
        )[0])
        failed_status = self.assert_success(self.call_cli("chat", "status", extra_environment=environment)[0])
        self.assertTrue(failed_status["missedPreviousPageSignal"], "Invalid Haiku responses must leave the classification pending.")
        blocked_response, _ = self.call_cli(
            "conversation", "send", chat_id, "--message", "Do not overtake Mars",
            expected_status=1, extra_environment=environment,
        )
        self.assert_failure(blocked_response, "operation_failed")
        blocked_history = json.loads(Path(str(executable) + ".history").read_text(encoding="utf-8"))
        self.assertFalse(
            any((turn.get("userText") or "") == "Do not overtake Mars" for turn in blocked_history.get("turns", [])),
            "An unresolved page decision must prevent the rejected prompt from reaching Claude.",
        )
        classifier_failure.unlink()
        recovered_status = self.assert_success(self.call_cli("chat", "status", extra_environment=environment)[0])
        self.assertFalse(recovered_status["missedPreviousPageSignal"])
        self.assertEqual(recovered_status["activePage"]["title"], "Mars")
        self.assert_success(self.call_cli(
            "conversation", "send", chat_id, "--message", "Another thought about Mars", extra_environment=environment
        )[0])
        recovered_messages = self.assert_success(self.call_cli(
            "chat", "page", "read", recovered_status["activePage"]["id"], extra_environment=environment
        )[0])["messages"]
        self.assertFalse(any(message["text"] == "Do not overtake Mars" for message in recovered_messages))
        self.assertIn("Another thought about Mars", [message["text"] for message in recovered_messages])
    # case-contract: test_service_reports_bridge_version | Playhouse opens one main board window titled with its worktree label, displays the transparent theater logo in the board header, keeps a fixed standard-width (216-point) Kanban sidebar, 8% wider than its previous 200-point width and left of the columns while they scroll, and places its Scheduled Tasks button inside the sidebar below the full logo header. The Dock AppIcon uses the same foreground artwork on a solid #2C2F36 background, and the bridge reports API version 1.
    def test_service_reports_bridge_version(self):
        response, _ = self.call_cli("status")
        status = self.assert_success(response)
        process_id = status.pop("processID")
        self.assertEqual(status, {"bridgeVersion": 1, "service": "Playhouse"})
        self.assertGreater(process_id, 0, "The bridge should report the daemon process that answered.")
        self.assertTrue(self.process_is_running(process_id))
        app_bundle = self.cli.parent.parent.parent
        assets_catalog = app_bundle / "Contents" / "Resources" / "Assets.car"
        catalog = subprocess.run(
            ["/usr/bin/assetutil", "--info", str(assets_catalog)],
            check=False,
            capture_output=True,
            text=True,
        )
        self.assertEqual(catalog.returncode, 0, f"Could not inspect the app asset catalog: {catalog.stderr}")
        assets = json.loads(catalog.stdout)
        bundled_assets = {asset.get("Name") for asset in assets}
        self.assertTrue(
            {"PlayhouseLogo", "AppIcon"}.issubset(bundled_assets),
            f"The app bundle should contain PlayhouseLogo and AppIcon assets; found {bundled_assets}.",
        )
        repository_root = Path(__file__).resolve().parent.parent
        app_icon = repository_root / "Playhouse/Assets.xcassets/AppIcon.appiconset/AppIcon.png"
        header_logo = repository_root / "Playhouse/Assets.xcassets/PlayhouseLogo.imageset/PlayhouseLogo.png"
        def bitmap(path, output):
            converted = subprocess.run(
                ["/usr/bin/sips", "-s", "format", "bmp", str(path), "--out", str(output)],
                check=False, capture_output=True, text=True,
            )
            self.assertEqual(converted.returncode, 0, converted.stderr)
            data = output.read_bytes()
            self.assertEqual(data[:2], b"BM")
            offset = struct.unpack_from("<I", data, 10)[0]
            width, signed_height = struct.unpack_from("<ii", data, 18)
            self.assertEqual(struct.unpack_from("<H", data, 28)[0], 32)
            self.assertLess(signed_height, 0, "Expected a top-down bitmap from sips")
            height = -signed_height

            def pixel(x, y):
                blue, green, red, alpha = data[offset + (y * width + x) * 4:offset + (y * width + x + 1) * 4]
                return red, green, blue, alpha

            return width, height, pixel

        with tempfile.TemporaryDirectory() as directory:
            icon_width, icon_height, icon_pixel = bitmap(app_icon, Path(directory) / "icon.bmp")
            logo_width, logo_height, logo_pixel = bitmap(header_logo, Path(directory) / "logo.bmp")
            background = icon_pixel(0, 0)[:3]
            self.assertEqual(background, (44, 47, 54), "The Dock icon should use the board's solid background.")
            self.assertLess(logo_pixel(0, 0)[3], 255, "The in-app logo should retain its transparent background.")

            def bounds(width, height, pixel, visible):
                points = ((x, y) for y in range(height) for x in range(width) if visible(pixel(x, y)))
                first = next(points, None)
                self.assertIsNotNone(first, "Artwork should have visible pixels")
                left = right = first[0]
                top = bottom = first[1]
                for x, y in points:
                    left, right = min(left, x), max(right, x)
                    top, bottom = min(top, y), max(bottom, y)
                return left, top, right, bottom

            icon_bounds = bounds(icon_width, icon_height, icon_pixel,
                                 lambda color: max(abs(color[channel] - background[channel]) for channel in range(3)) > 25)
            logo_bounds = bounds(logo_width, logo_height, logo_pixel, lambda color: color[3] > 25)

            def sample(pixel, box, x, y):
                left, top, right, bottom = box
                color = pixel(left + (right - left) * x // 63, top + (bottom - top) * y // 63)
                alpha = color[3] / 255
                return tuple(round(color[channel] * alpha + background[channel] * (1 - alpha)) for channel in range(3))

            differences = [
                abs(icon_pixel(icon_bounds[0] + (icon_bounds[2] - icon_bounds[0]) * x // 63,
                               icon_bounds[1] + (icon_bounds[3] - icon_bounds[1]) * y // 63)[channel]
                    - sample(logo_pixel, logo_bounds, x, y)[channel])
                for y in range(64) for x in range(64) for channel in range(3)
            ]
            self.assertLess(sum(differences) / len(differences), 10,
                            "The Dock icon and header should contain the same artwork.")
    # case-contract: test_app_override_rejects_incompatible_bundles | Explicit app overrides reject obsolete compatibility metadata, foreign worktree or bridge identities, test IDs that do not match the current worktree, and nonisolated test data before launching; the current app preserves a saved draft across restart.
    def test_app_override_rejects_incompatible_bundles(self):
        task = self.assert_success(self.call_cli("task", "create", "--title", "Protected store", "--prompt", "Fixture task description.", "--root", self.primary)[0])
        self.assert_success(self.call_cli("task", "prompt", task["id"], "--text", "Protected draft", "--status", "Backlog")[0])
        root = Path(__file__).resolve().parent.parent
        launch_contract = subprocess.run(
            ["python3", str(root / "scripts/check-app-launch-contract.py"), str(self.cli.parent.parent.parent), str(root), str(self.data_directory)],
            check=False,
            capture_output=True,
            text=True,
        )
        self.assertEqual(
            launch_contract.returncode,
            0,
            f"App launch contract check failed: {launch_contract.stdout}\n{launch_contract.stderr}",
        )
        self.assertEqual(self.assert_success(self.call_cli("task", "get", task["id"])[0])["savedPrompt"], "Protected draft")
    # case-contract: test_worktree_app_profiles_isolate_identity_and_store | The primary and linked source worktrees resolve to stable, distinct app and XPC identities, build paths, data stores, logs, and managed worktree roots, each worktree root inside its data directory. The run.sh launch resolver replaces a PLAYHOUSE_DATA_DIRECTORY inherited from another Playhouse app's profile directory with the launching worktree's own and rejects any other foreign data directory, and run.sh drops PLAYHOUSE_BRIDGE_SERVICE_NAME and PLAYHOUSE_BRIDGE_SOCKET_PATH inherited from another Playhouse app, saying so, while keeping the launching worktree's own bridge. run.sh keeps this worktree's running app open during its build and stops this worktree's app and bridge daemon only once, after the build and right before it opens the app, so a daemon started from the previous build during the build cannot serve the new app. A saved conversation remains visible after an app restart.
    def test_worktree_app_profiles_isolate_identity_and_store(self):
        script = Path(__file__).resolve().parent / "app-profile.sh"
        linked = self.fixture / "existing-worktree"

        def profile(path):
            result = subprocess.run(["bash", str(script), str(path)], check=True, capture_output=True, text=True)
            return json.loads(result.stdout)

        primary_profile = profile(self.primary)
        linked_profile = profile(linked)
        self.assertEqual(primary_profile["kind"], "primary")
        self.assertEqual(primary_profile["bundleID"], "com.playhouse.app")
        self.assertEqual(primary_profile["dataDirectory"], str(Path.home() / "Library/Application Support/Playhouse"))
        self.assertEqual(linked_profile, profile(linked))
        self.assertEqual(linked_profile["kind"], "linked")
        self.assertNotEqual(primary_profile["bundleID"], linked_profile["bundleID"])
        self.assertNotEqual(primary_profile["bridgeID"], linked_profile["bridgeID"])
        self.assertNotEqual(primary_profile["derivedData"], linked_profile["derivedData"])
        self.assertNotEqual(primary_profile["dataDirectory"], linked_profile["dataDirectory"])
        self.assertNotEqual(primary_profile["logFile"], linked_profile["logFile"])
        self.assertNotEqual(primary_profile["worktreeRoot"], linked_profile["worktreeRoot"])
        for app_profile in [primary_profile, linked_profile]:
            self.assertEqual(app_profile["worktreeRoot"], str(Path(app_profile["dataDirectory"]) / "task-worktrees"))
        self.assertTrue(linked_profile["bundleID"].endswith(linked_profile["key"]))
        self.assertEqual(linked_profile["bridgeID"], linked_profile["bundleID"] + ".bridge")
        self.assertEqual(
            linked_profile["dataDirectory"],
            str(Path.home() / "Library/Application Support/Playhouse/Worktrees" / linked_profile["key"]),
        )
        verify_build = 'source "$1"; playhouse_load_app_profile "$2"; playhouse_verify_build_identity "$3"'
        self.assertEqual(subprocess.run(
            ["bash", "-c", verify_build, "profile-check", str(script), str(linked), linked_profile["bundleID"]],
            capture_output=True, text=True,
        ).returncode, 0)
        self.assertNotEqual(subprocess.run(
            ["bash", "-c", verify_build, "profile-check", str(script), str(linked), primary_profile["bundleID"]],
            capture_output=True, text=True,
        ).returncode, 0)
        self.assertNotEqual(subprocess.run(
            ["bash", "-c", verify_build, "profile-check", str(script), str(self.primary), linked_profile["bundleID"] + ".e2e.fixture"],
            capture_output=True, text=True,
        ).returncode, 0)
        # scripts/run.sh launches with this resolver's directory. A value inherited
        # from another Playhouse app's agent session gives way to the profile's own.
        resolve_launch = 'source "$1"; playhouse_load_app_profile "$2"; playhouse_resolve_launch_data_directory'

        def launch_directory(path, inherited):
            environment = os.environ.copy()
            environment.pop("PLAYHOUSE_DATA_DIRECTORY", None)
            if inherited is not None:
                environment["PLAYHOUSE_DATA_DIRECTORY"] = inherited
            return subprocess.run(
                ["bash", "-c", resolve_launch, "launch-check", str(script), str(path)],
                env=environment, capture_output=True, text=True,
            )

        other_linked_directory = str(Path(linked_profile["dataDirectory"]).parent / "w0123456789abcdef")
        for path, app_profile, inherited, ignored in [
            (linked, linked_profile, None, False),
            (linked, linked_profile, linked_profile["dataDirectory"], False),
            (linked, linked_profile, primary_profile["dataDirectory"], True),
            (linked, linked_profile, primary_profile["dataDirectory"] + "/", True),
            (linked, linked_profile, other_linked_directory, True),
            (self.primary, primary_profile, linked_profile["dataDirectory"], True),
        ]:
            result = launch_directory(path, inherited)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout.strip(), app_profile["dataDirectory"], f"Inherited {inherited!r}")
            self.assertEqual("inherited from another Playhouse app" in result.stderr, ignored, result.stderr)
        for path, inherited in [
            (linked, str(self.data_directory)),
            (linked, str(Path(linked_profile["dataDirectory"]).parent / "not-a-profile")),
            (self.primary, str(self.data_directory)),
        ]:
            result = launch_directory(path, inherited)
            self.assertEqual(result.returncode, 2, result.stdout)
            self.assertEqual(result.stdout, "")
            self.assertIn("PLAYHOUSE_DATA_DIRECTORY points elsewhere", result.stderr)
        # `open -n` hands the app run.sh's whole environment, so run.sh drops a
        # bridge daemon override inherited from another Playhouse app.
        clear_bridge = ('source "$1"; playhouse_load_app_profile "$2"; playhouse_clear_inherited_bridge_overrides; '
                        'printf "%s|%s" "${PLAYHOUSE_BRIDGE_SERVICE_NAME:-}" "${PLAYHOUSE_BRIDGE_SOCKET_PATH:-}"')

        def cleared_bridge(service, socket):
            environment = os.environ.copy()
            for name, value in (("PLAYHOUSE_BRIDGE_SERVICE_NAME", service), ("PLAYHOUSE_BRIDGE_SOCKET_PATH", socket)):
                environment.pop(name, None)
                if value is not None:
                    environment[name] = value
            return subprocess.run(["bash", "-c", clear_bridge, "bridge-check", str(script), str(linked)],
                                  env=environment, capture_output=True, text=True)

        own_bridge = linked_profile["bridgeID"]
        for service, socket, expected, ignored in [
            (primary_profile["bridgeID"], "/tmp/parent-bridge.sock", "|", True),
            (None, "/tmp/parent-bridge.sock", "|", True),
            (own_bridge, "/tmp/own-bridge.sock", f"{own_bridge}|/tmp/own-bridge.sock", False),
            (None, None, "|", False),
        ]:
            result = cleared_bridge(service, socket)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout, expected, f"Inherited {service!r} / {socket!r}")
            self.assertEqual("inherited from another Playhouse app" in result.stderr, ignored, result.stderr)
        self.assertIn("playhouse_clear_inherited_bridge_overrides\nopen -n", (Path(script).parent / "run.sh").read_text(encoding="utf-8"),
                      "run.sh must clear inherited bridge overrides right before it opens the app.")
        run_script = (Path(script).parent / "run.sh").read_text(encoding="utf-8")
        self.assertIn('terminate_running_playhouse "now that the new build is ready"\nplayhouse_clear_inherited_bridge_overrides\nopen -n', run_script,
                      "run.sh must stop a daemon started from the previous build right before it opens the app.")
        self.assertLess(run_script.index("xcodebuild build"), run_script.index('terminate_running_playhouse "now that the new build is ready"'),
                        "run.sh must stop the previous build's processes after xcodebuild finishes.")
        self.assertEqual(run_script.count("\nterminate_running_playhouse "), 1,
                         "run.sh must keep the running app open during the build and stop it only once, after the build.")
        # The bridge daemon and CLI ship flat in Contents/MacOS and resolve
        # their identity from this same Info.plist via `Bundle.main` (no
        # separate XPC bundle/Info.plist to cross-check anymore); the service
        # name is just that identifier plus ".bridge", matching
        # `BridgeContract.serviceName(forApplication:)`.
        app_info = plistlib.loads((self.cli.parent.parent / "Info.plist").read_bytes())
        self.assertEqual(arguments.service_name, app_info["CFBundleIdentifier"] + ".bridge")

        task = self.assert_success(self.call_cli("task", "create", "--title", "Profile restart", "--prompt", "Fixture task description.", "--root", self.primary)[0])
        saved = self.assert_success(self.call_cli(
            "task", "prompt", task["id"], "--text", "Keep this draft after restart.", "--status", "Backlog",
        )[0])
        self.assertEqual(saved["savedPrompt"], "Keep this draft after restart.")
        self.assertTrue((self.data_directory / "Playhouse-v2.store").is_file())
        reopened = self.assert_success(self.call_cli("task", "get", task["id"])[0])
        self.assertEqual(reopened["title"], "Profile restart")
        self.assertEqual(reopened["savedPrompt"], "Keep this draft after restart.")
    # case-contract: test_task_creation_rejects_invalid_title_roots_and_missing_folder | New Task opens with the repository picker closed and composer focused; no selected repository is valid and shows no red missing-folder warning when the required repository root is configured. A standalone conversation can be sent without repository roots, while GUI and CLI reject sends if the configured repository root is missing. The UI and CLI accept standalone sends after the root is configured. The CLI accepts empty-root tasks and rejects blank titles, missing folders, unavailable roots, and invalid merge targets.
    def test_task_creation_rejects_invalid_title_roots_and_missing_folder(self):
        response, _ = self.call_cli(
            "task", "create", "--title", "   ", "--prompt", "Fixture task description.", "--root", self.primary,
            expected_status=2,
        )
        self.assert_failure(response, "invalid_argument")

        response, _ = self.call_cli(
            "task", "create", "--title", "Bad merge target", "--prompt", "Fixture task description.", "--repo", self.primary,
            "--merge-target", f"{self.primary}=not-a-local-branch", expected_status=2,
        )
        self.assert_failure(response, "invalid_argument")
        self.assertIn("must name an existing local branch", response["error"]["message"])

        response, _ = self.call_cli("task", "create", "--title", "No roots", "--prompt", "Fixture task description.")
        empty_task = self.assert_success(response)
        self.assertEqual(empty_task["workspaceRoots"], [])
        self.assertEqual(empty_task["repositoryWorktrees"], [])
        persisted_empty_task = self.assert_success(self.call_cli("task", "get", empty_task["id"])[0])
        self.assertEqual(persisted_empty_task["title"], "No roots")
        self.assertEqual(persisted_empty_task["workspaceRoots"], [])
        self.assertEqual(persisted_empty_task["repositoryWorktrees"], [])
        self.complete_fixture_turn(empty_task["id"], message="Explain what nothingness means without editing a repository.")
        completed_standalone = self.assert_success(self.call_cli("task", "get", empty_task["id"])[0])
        self.assertEqual(completed_standalone["workspaceRoots"], [])
        self.assertEqual(completed_standalone["repositoryWorktrees"], [])
        self.assertEqual(completed_standalone["status"], "Review")
        main_history_path = self.data_directory / "codex-fixture.history"
        main_history = json.loads(main_history_path.read_text(encoding="utf-8"))
        instructions = main_history["threadStartDeveloperInstructions"]
        self.assertIn("read-only inspection of returned source paths", instructions)
        self.assertIn("Add a repository to this task only when you intend to create or commit changes in it", instructions)
        self.assertIn("workspace repos list", instructions)
        self.assertIn("task repository add", instructions)
        self.assertIn("Do not interrupt the user or ask them to confirm the selection merely because the task appears unrelated.", instructions)
        self.assertFalse((self.data_directory / "codex-fixture.assessment.history").exists(), "A new conversation should not launch a separate repository assessment.")
        deleted, _ = self.call_cli("task", "delete", empty_task["id"])
        self.assertTrue(self.assert_success(deleted)["deleted"])

        no_root_task = self.assert_success(self.call_cli("task", "create", "--title", "Root required", "--prompt", "Fixture task description.")[0])
        self.assert_success(self.call_cli("settings", "clear-parent")[0])
        response, _ = self.call_cli(
            "conversation", "send", no_root_task["id"], "--message", "This must be blocked",
            expected_status=1, extra_environment=self.install_codex_fixture("codex-fixture-root-required"),
        )
        self.assert_failure(response, "settings_required")
        untouched = self.assert_success(self.call_cli("task", "get", no_root_task["id"])[0])
        self.assertEqual(untouched["status"], "Backlog", "Missing root validation must happen before task state changes.")
        self.assertEqual(untouched.get("savedPrompt"), "Fixture task description.", "A rejected send must leave the saved prompt untouched.")
        self.assertEqual(untouched["repositoryWorktrees"], [])
        self.assert_success(self.call_cli("settings", "set-parent", self.fixture / "suggested-parent")[0])
        deleted, _ = self.call_cli("task", "delete", no_root_task["id"])
        self.assertTrue(self.assert_success(deleted)["deleted"])

        response, _ = self.call_cli(
            "task", "create", "--title", "Missing folder", "--prompt", "Fixture task description.", "--root", self.fixture / "missing",
            expected_status=2,
        )
        self.assert_failure(response, "invalid_argument")
    # case-contract: test_task_creation_persists_ordered_roots_across_fresh_connections | A directly created conversation can add repositories in order, edit pending branch settings, and add a context folder; these settings persist across fresh connections without creating branches or worktrees before the first send. The conversation shows the additional context folder without repeating repository worktrees in a Working in summary. Saving an unsent prompt records task creation, prompt save, and subsequent reads with safe argument metadata, result state, and outcome while excluding prompt text.
    def test_task_creation_persists_ordered_roots_across_fresh_connections(self):
        branch_token = uuid.uuid4().hex[:8]
        title = f"Bridge task {branch_token}"
        generated_branch = f"bridge-task-{branch_token}"
        created = self.create_repo_task(
            title, [self.primary], branch_from={str(self.primary): "branch-source"},
            merge_targets={str(self.primary): "branch-source"}, roots=[self.custom]
        )
        task_id = created["id"]
        self.assertEqual(created["status"], "Backlog")
        self.assertEqual(created["repositoryWorktrees"][0]["repositoryPath"], str(self.primary))
        self.assertEqual(created["repositoryWorktrees"][0]["branch"], "auto")
        self.assertTrue(created["repositoryWorktrees"][0]["isPending"])
        self.assertEqual(created["repositoryWorktrees"][0]["worktreePath"], str(self.primary))
        self.assertEqual(created["repositoryWorktrees"][0]["branchFrom"], "branch-source")
        self.assertEqual(created["repositoryWorktrees"][0]["mergeTarget"], "branch-source")
        self.assertFalse(self.branch_exists(self.primary, generated_branch))
        self.assertEqual(created["contextFolders"], [str(self.custom)])
        self.assertEqual(created["workspaceRoots"], [str(self.primary), str(self.custom)])
        prompt = f"PROMPT_TEXT_NOT_IN_DIAGNOSTICS_{uuid.uuid4().hex}"
        response, _ = self.call_cli("task", "prompt", task_id, "--text", prompt)
        self.assertEqual(self.assert_success(response)["savedPrompt"], prompt)

        # Each CLI call starts a new process and XPC connection over the same real store.
        response, _ = self.call_cli("task", "get", task_id)
        task = self.assert_success(response)
        self.assertEqual(task["title"], title)
        self.assertEqual(task["repositoryWorktrees"], created["repositoryWorktrees"])
        self.assertEqual(task["workspaceRoots"], created["workspaceRoots"])
        response, _ = self.call_cli("board", "list")
        self.assertEqual([task["id"] for task in self.assert_success(response)["tasks"]], [task_id])
        operation_events = [
            event for event in self.diagnostic_events()
            if event.get("event") in {"bridge.request.started", "bridge.request.succeeded"}
        ]
        created_event = next(
            event for event in operation_events
            if event.get("event") == "bridge.request.succeeded" and event.get("command") == "task.create"
        )
        self.assertEqual(created_event.get("result.status"), "Backlog")
        self.assertEqual(created_event.get("argument.repositories.0.repositoryPath"), str(self.primary))
        task_write = next(
            event for event in self.diagnostic_events()
            if event.get("event") == "persistence.write.succeeded"
            and "create(title:repositories:contextFolders:" in event.get("operation", "")
        )
        self.assertEqual(task_write.get("entity"), "BoardTask")
        worktree_read = next(
            event for event in self.diagnostic_events()
            if event.get("event") == "git.operation.succeeded"
            and event.get("operation") == "worktree.prepare"
        )
        self.assertEqual(worktree_read.get("repositoryPath"), str(self.primary))
        get_event = next(
            event for event in operation_events
            if event.get("event") == "bridge.request.succeeded" and event.get("command") == "task.get"
        )
        self.assertEqual(get_event.get("argument.taskID"), task_id)
        self.assertTrue(any(
            event.get("event") == "persistence.read.succeeded"
            and event.get("operation") == "BoardTaskManager.requireTask"
            and event.get("taskID") == task_id
            for event in self.diagnostic_events()
        ))
        list_event = next(
            event for event in operation_events
            if event.get("event") == "bridge.request.succeeded" and event.get("command") == "board.list"
        )
        self.assertEqual(list_event.get("resultKind"), "object")
        prompt_event = next(
            event for event in operation_events
            if event.get("event") == "bridge.request.succeeded" and event.get("command") == "task.prompt.save"
        )
        self.assertEqual(prompt_event.get("argument.prompt.utf8Bytes"), str(len(prompt.encode("utf-8"))))
        self.assertNotIn(prompt, json.dumps(self.diagnostic_events()))
    # case-contract: test_task_creation_reuses_existing_branch_worktree | A selected existing branch remains pending until task start, then reuses its exact existing worktree path.
    def test_task_creation_reuses_existing_branch_worktree(self):
        existing = self.worktree_directory / "external-existing"
        branch = f"already-here-{uuid.uuid4().hex[:8]}"
        self.run_git(self.primary, "worktree", "add", "-b", branch, str(existing), "main")
        task = self.create_repo_task("Reuse branch", [self.primary], branches={str(self.primary): branch})
        self.assertTrue(task["repositoryWorktrees"][0]["isPending"])
        self.assertEqual(task["repositoryWorktrees"][0]["worktreePath"], str(self.primary))
        self.complete_fixture_turn(task["id"])
        task = self.assert_success(self.call_cli("task", "get", task["id"])[0])
        self.assertFalse(task["repositoryWorktrees"][0]["isPending"])
        self.assertEqual(task["repositoryWorktrees"][0]["worktreePath"], str(existing))
        self.assertFalse(task["repositoryWorktrees"][0]["createdByPlayhouse"])
    # case-contract: test_task_creation_creates_worktrees_in_multiple_repositories | The conversation picker can add multiple repositories; unset branch settings display defaults and persist pending auto records resolved to local main without creating branches or worktrees before the first send.
    def test_task_creation_creates_worktrees_in_multiple_repositories(self):
        branch_token = uuid.uuid4().hex[:8]
        title = f"Multi repository {branch_token}"
        generated_branch = f"multi-repository-{branch_token}"
        task = self.create_repo_task(title, [self.secondary, self.primary])
        self.assertEqual([item["repositoryPath"] for item in task["repositoryWorktrees"]], [str(self.secondary), str(self.primary)])
        self.assertEqual([item["branch"] for item in task["repositoryWorktrees"]], ["auto", "auto"])
        self.assertTrue(all(item["isPending"] for item in task["repositoryWorktrees"]))
        self.assertEqual([item["branchFrom"] for item in task["repositoryWorktrees"]], ["main", "main"])
        for repository in [self.secondary, self.primary]:
            self.assertFalse(self.branch_exists(repository, generated_branch))
        self.assertEqual(task["workspaceRoots"], [str(self.secondary), str(self.primary)])
    # case-contract: test_task_creation_supports_non_git_folder_only_context | A folder-only task persists its context without Git worktrees and reaches Done after a successful turn without attempting a merge.
    def test_task_creation_supports_non_git_folder_only_context(self):
        task = self.create_task("Folder only", roots=[self.custom])
        self.assertEqual(task["repositoryWorktrees"], [])
        self.assertEqual(task["contextFolders"], [str(self.custom)])
        self.assertEqual(task["workspaceRoots"], [str(self.custom)])
        self.complete_fixture_turn(task["id"])
        completed, _ = self.call_cli("task", "move", task["id"], "Done")
        self.assertEqual(self.assert_success(completed)["status"], "Done")
        self.assertEqual(self.assert_success(self.call_cli("task", "get", task["id"])[0])["contextFolders"], [str(self.custom)])
    # case-contract: test_task_creation_rejects_worktree_assigned_to_active_task | Adding a repository branch already assigned to another active task is rejected in the new conversation, and the existing task and repository reservation remain unchanged.
    def test_task_creation_rejects_worktree_assigned_to_active_task(self):
        first = self.create_repo_task("First owner", [self.primary], branches={str(self.primary): "active-shared"}, materialize=True)
        response, _ = self.call_cli(
            "task", "create", "--title", "Second owner", "--prompt", "Fixture task description.", "--repo", self.primary,
            "--branch", f"{self.primary}=active-shared", expected_status=2,
        )
        self.assert_failure(response, "invalid_argument")
        self.assertIn("is already used by task \"First owner\"", response["error"]["message"])
        self.assertIn("`active-shared`", response["error"]["message"])
        self.assertEqual(len(self.assert_success(self.call_cli("task", "list")[0])["tasks"]), 1)
        self.assertTrue(Path(first["repositoryWorktrees"][0]["worktreePath"]).is_dir())
    # case-contract: test_task_creation_serializes_repository_branch_reservations | Two concurrent CLI/XPC creates targeting the same explicit branch in one repository serialize through a shared cross-process lock, leaving exactly one persisted active task and rejecting the other.
    def test_task_creation_serializes_repository_branch_reservations(self):
        branch = f"concurrent-reservation-{uuid.uuid4().hex[:8]}"
        barrier = RepositoryAllocationLockBarrier(self.data_directory, self.primary)
        processes = []
        commands = []
        try:
            for title in ["Reservation contender one", "Reservation contender two"]:
                command = [
                    "task", "create", "--title", title, "--prompt", "Fixture task description.",
                    "--repo", self.primary,
                    "--branch", f"{self.primary}={branch}",
                ]
                commands.append(command)
                processes.append(self.start_cli(*command))
            time.sleep(1)
            for process, command in zip(processes, commands):
                if process.poll() is not None:
                    stdout, stderr = process.communicate()
                    self.fail(f"Create exited before the repository lock was released: {command}; stdout={stdout!r}; stderr={stderr!r}")
        finally:
            barrier.release()
            for process in processes:
                if process.poll() is None:
                    try:
                        process.wait(timeout=90)
                    except subprocess.TimeoutExpired:
                        process.terminate()
                        process.wait(timeout=20)

        outcomes = []
        for process, command in zip(processes, commands):
            stdout, stderr = process.communicate(timeout=20)
            lines = [line for line in stdout.splitlines() if line.strip()]
            self.assertTrue(lines, f"CLI returned no JSON for {command}: {stderr}")
            response = json.loads(lines[-1])
            self.assertEqual(response.get("version"), 1)
            outcomes.append((process.returncode, response))

        self.assertEqual(sorted(status for status, _ in outcomes), [0, 2])
        successful = [response for _, response in outcomes if response.get("ok")]
        rejected = [response for _, response in outcomes if not response.get("ok")]
        self.assertEqual(len(successful), 1)
        self.assertEqual(len(rejected), 1)
        self.assertEqual(rejected[0].get("error", {}).get("code"), "invalid_argument")
        self.assertIn("is already used by task", rejected[0]["error"]["message"])

        tasks = self.assert_success(self.call_cli("task", "list")[0])["tasks"]
        self.assertEqual(len(tasks), 1)
        task = self.assert_success(self.call_cli("task", "get", tasks[0]["id"])[0])
        record = task["repositoryWorktrees"][0]
        self.assertEqual(record["branch"], branch)
        self.assertTrue(record["isPending"])
    # case-contract: test_task_store_serializes_cross_process_writes | If another process holds the shared task-store write lock when a Codex turn completes after an explicit completed outcome, final status persistence waits and then saves Review status and full history across fresh CLI/XPC reads. Correlated persistence diagnostics include task ID, store path, lock wait, attempts, and retry count; task reads correlate started and completed events by read ID and store path, while failed reads include store file and sidecar state. Reopening the conversation in the UI shows the saved exchange without a store error.
    def test_task_store_serializes_cross_process_writes(self):
        task = self.create_repo_task("Store write contention", [self.primary])
        fixture_path = self.data_directory / "codex-fixture-store-write-success-wait"
        self.assertFalse(fixture_path.exists(), "A new, unique per-case fixture path must not replace an existing file.")
        copy_file(Path(__file__).resolve().parent / "fixtures" / "codex-app-server-fixture.py", fixture_path)
        fixture_path.chmod(0o755)
        (self.data_directory / ".playhouse-codex-fixture-owner").write_text(
            "Playhouse test owns this Codex protocol fixture (v1).\n", encoding="utf-8"
        )
        ready = Path(str(fixture_path) + ".resolve-ready")
        continuation = Path(str(fixture_path) + ".resolve-continue")
        command = ["conversation", "send", task["id"], "--message", "Persist this completed turn."]
        process = self.start_cli(
            *command,
            extra_environment={"PLAYHOUSE_E2E_CODEX_EXECUTABLE": str(fixture_path)},
        )
        barrier = None
        try:
            deadline = time.monotonic() + 15
            while not ready.is_file() and time.monotonic() < deadline:
                if process.poll() is not None:
                    stdout, stderr = process.communicate()
                    self.fail(f"The fixture turn ended before it could be held: stdout={stdout!r}; stderr={stderr!r}")
                time.sleep(0.02)
            self.assertTrue(ready.is_file(), "The real app-server fixture did not pause inside the active turn.")
            outcome, _ = self.call_cli("task", "outcome", task["id"], "completed")
            self.assertEqual(self.assert_success(outcome)["outcome"], "completed")
            barrier = TaskStoreWriteLockBarrier(self.data_directory)
            continuation.write_text("Release the completed fixture turn.\n", encoding="utf-8")

            deadline = time.monotonic() + 15
            completed_event_seen = False
            while time.monotonic() < deadline:
                diagnostics = self.data_directory / "Diagnostics.jsonl"
                if diagnostics.is_file():
                    completed_event_seen = any(
                        event.get("event") == "codex.turn.ended" and event.get("turnStatus") == "completed"
                        for event in (json.loads(line) for line in diagnostics.read_text(encoding="utf-8").splitlines() if line.strip())
                    )
                if completed_event_seen:
                    break
                time.sleep(0.02)
            self.assertTrue(completed_event_seen, "Codex should finish before final task-status persistence begins.")
            time.sleep(0.2)
            self.assertIsNone(process.poll(), "The completed turn must wait for the shared store write lock.")
            current, _ = self.call_cli("task", "get", task["id"])
            self.assertEqual(self.assert_success(current)["status"], "In Progress")
        except BaseException:
            continuation.touch(exist_ok=True)
            if barrier is not None:
                barrier.release()
            if process.poll() is None:
                process.terminate()
                process.communicate(timeout=20)
            raise
        finally:
            continuation.touch(exist_ok=True)
            if barrier is not None:
                barrier.release()

        response, _ = self.finish_cli(process, command)
        self.assert_success(response)
        current, _ = self.call_cli("task", "get", task["id"])
        current = self.assert_success(current)
        self.assertEqual(current["status"], "Review")
        self.assertIsNone(current.get("pendingSubmittedPrompt"))
        history, _ = self.call_cli(
            "conversation", "history", task["id"],
            extra_environment={"PLAYHOUSE_E2E_CODEX_EXECUTABLE": str(fixture_path)},
        )
        messages = self.assert_success(history)["messages"]
        self.assertTrue(any(item["role"] == "user" and item["text"] == "Persist this completed turn." for item in messages))
        self.assertTrue(any(
            item["role"] == "assistant" and item["text"] == "Answers received: Blue / fixture-secret."
            for item in messages
        ))
        failures = [
            json.loads(line) for line in (self.data_directory / "Diagnostics.jsonl").read_text(encoding="utf-8").splitlines()
            if json.loads(line).get("taskID") == task["id"] and json.loads(line).get("event") == "conversation.send.failed"
        ]
        self.assertEqual(failures, [], "A transient store lock must not surface as a failed conversation send.")
        store_write_events = [
            json.loads(line) for line in (self.data_directory / "Diagnostics.jsonl").read_text(encoding="utf-8").splitlines()
            if json.loads(line).get("taskID") == task["id"]
            and json.loads(line).get("event") == "persistence.write.lock_acquired"
        ]
        self.assertTrue(store_write_events, "The final task save should log when its shared store lock is acquired.")
        waited_write = next(event for event in store_write_events if int(event.get("lockWaitMilliseconds", "0")) > 0)
        self.assertEqual(waited_write["storePath"], str(self.data_directory / "Playhouse-v2.store"))
        matching_success = next(
            json.loads(line) for line in (self.data_directory / "Diagnostics.jsonl").read_text(encoding="utf-8").splitlines()
            if (event := json.loads(line)).get("taskID") == task["id"]
            and event.get("event") == "persistence.write.succeeded"
            and event.get("writeID") == waited_write["writeID"]
        )
        self.assertEqual(matching_success["attemptCount"], "1")
        self.assertEqual(matching_success["retryCount"], "0")

        read_events = [
            json.loads(line) for line in (self.data_directory / "Diagnostics.jsonl").read_text(encoding="utf-8").splitlines()
            if json.loads(line).get("taskID") == task["id"]
            and json.loads(line).get("operation") == "BoardTaskManager.requireTask"
            and json.loads(line).get("event") in {"persistence.read.started", "persistence.read.succeeded"}
        ]
        successful_read = next(event for event in read_events if event["event"] == "persistence.read.succeeded")
        read_id = successful_read["readID"]
        matching_read_start = next(
            event for event in read_events
            if event["event"] == "persistence.read.started" and event.get("readID") == read_id
        )
        expected_store_path = str(self.data_directory / "Playhouse-v2.store")
        snapshot_prefixes = ("storeDirectory", "storeFile", "storeWAL", "storeSHM")
        for read_event in (matching_read_start, successful_read):
            self.assertEqual(read_event["storePath"], expected_store_path)
            self.assertFalse(
                any(key.startswith(snapshot_prefixes) for key in read_event),
                f"Successful read events should omit filesystem snapshots: {read_event}",
            )
        self.assertIn("durationMilliseconds", successful_read)
    # case-contract: test_persistence_store_open_failure_records_detailed_error | A real ModelContainer open failure against an isolated invalid store path returns an error and durably logs the phase, exact underlying NSError domain/code/userInfo, resolved store path, file/sidecar snapshot, and read-only schema probe failure; the paired visible UI case keeps Playhouse open on its normal board while the same isolated CLI/XPC request fails and verifies the persisted diagnostic.
    def test_persistence_store_open_failure_records_detailed_error(self):
        failure_directory = self.data_directory / "invalid-store-open"
        failure_directory.mkdir()
        store = failure_directory / "Playhouse-v2.store"
        store.mkdir()

        response, _ = self.call_cli(
            "task", "list", expected_status=1,
            extra_environment={"PLAYHOUSE_DATA_DIRECTORY": str(failure_directory)},
        )
        self.assertFalse(response["ok"], response)
        diagnostic_path = failure_directory / "Diagnostics.jsonl"
        events = [
            json.loads(line) for line in diagnostic_path.read_text(encoding="utf-8").splitlines()
            if line.strip()
        ]
        failed_open = next(event for event in events if event.get("event") == "persistence.store.open.failed")
        self.assertEqual(failed_open["phase"], "model-container-open")
        self.assertEqual(failed_open["storePath"], str(store))
        self.assertEqual(failed_open["storeFileExists"], "true")
        self.assertIn("storeWALExists", failed_open)
        self.assertIn("storeSHMExists", failed_open)
        self.assertTrue(failed_open.get("errorDescription"))
        self.assertTrue(failed_open.get("error0Domain"))
        self.assertTrue(failed_open.get("error0Code"))
        self.assertIn("error0UserInfoKeys", failed_open)
        self.assertIn("error0UserInfoKeyCount", failed_open)
        self.assertIn("error0UserInfo", failed_open)
        self.assertEqual(failed_open["schemaProbeResult"], "open-failed")
        self.assertTrue(failed_open.get("schemaProbeSQLiteMessage"))
    # case-contract: test_persistence_read_failure_records_detailed_error | A real SwiftData fetch failure against an isolated store with a missing task column returns an error and logs a correlated read ID, NSError domain/code/userInfo, store path, file/sidecar snapshot, and the exact missing-column message from a read-only schema probe before the CLI/XPC request completes; the paired visible UI case keeps the normal task board open and verifies the same isolated failure record.
    def test_persistence_read_failure_records_detailed_error(self):
        self.create_task("Missing column read failure")
        store = self.data_directory / "Playhouse-v2.store"
        with sqlite3.connect(store) as database:
            database.execute("ALTER TABLE ZBOARDTASK DROP COLUMN ZPROGRESSLABEL")

        response, _ = self.call_cli("task", "list", expected_status=1)
        self.assertFalse(response["ok"], response)
        events = self.diagnostic_events()
        failed_read = next(
            event for event in events
            if event.get("event") == "persistence.read.failed"
            and event.get("operation") == "BoardTaskManager.list"
        )
        self.assertTrue(failed_read.get("readID"))
        self.assertEqual(failed_read["storePath"], str(store))
        self.assertEqual(failed_read["storeFileExists"], "true")
        self.assertIn("storeWALExists", failed_read)
        self.assertIn("storeSHMExists", failed_read)
        self.assertTrue(failed_read.get("errorDescription"))
        self.assertTrue(failed_read.get("error0Domain"))
        self.assertTrue(failed_read.get("error0Code"))
        self.assertIn("error0UserInfoKeys", failed_read)
        self.assertIn("error0UserInfoKeyCount", failed_read)
        self.assertIn("error0UserInfo", failed_read)
        self.assertEqual(failed_read["schemaProbeResult"], "prepare-failed")
        self.assertEqual(failed_read["schemaProbeSQLiteCode"], "1")
        self.assertIn("no such column: t0.ZPROGRESSLABEL", failed_read["schemaProbeSQLiteMessage"])
        self.assertTrue(any(
            event.get("event") == "persistence.read.started"
            and event.get("readID") == failed_read["readID"]
            and event.get("storePath") == str(store)
            for event in events
        ))
