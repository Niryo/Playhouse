from test_bridge_support import *
from test_bridge_support import __file__

class BridgeTestCases27:
    def make_update_fixture(self, tamper=None, served_seconds=0, root="update-fixture", **release):
        """A stable 0.1.0 copy of this test build and a signed feed offering 0.2.0, served over
        HTTP on 127.0.0.1 (see scripts/make-update-fixture.py), plus the environment pointing the
        bridge at them. The archive takes served_seconds to send; release options (architecture,
        minimum_system) describe what the release runs on."""
        fixture_root = self.data_directory / root
        command = ["python3", str(Path(__file__).resolve().parent / "make-update-fixture.py"),
                   "--source-app", str(self.cli.parent.parent.parent),
                   "--root", str(fixture_root),
                   "--base-url", self.serve_update_feed(fixture_root / "feed", served_seconds)]
        if tamper:
            command += ["--tamper", tamper]
        for name, value in release.items():
            command += ["--" + name.replace("_", "-"), value]
        made = subprocess.run(command, check=False, capture_output=True, text=True, timeout=300)
        self.assertEqual(made.returncode, 0, f"The update fixture failed: {made.stdout}\n{made.stderr}")
        fixture = json.loads(made.stdout)
        environment = {
            "PLAYHOUSE_E2E_UPDATE_FEED_URL": fixture["feedURL"],
            "PLAYHOUSE_E2E_UPDATE_API_URL": fixture["releaseAPIURL"],
            "PLAYHOUSE_E2E_UPDATE_PUBLIC_KEY": fixture["publicKey"],
            "PLAYHOUSE_E2E_UPDATE_TARGET_APP": fixture["installedApp"],
        }
        return fixture, environment

    def serve_update_feed(self, directory, seconds):
        """Serves a fixture feed folder over HTTP on 127.0.0.1 until the case ends; returns its address."""
        server = subprocess.Popen(
            ["python3", str(Path(__file__).resolve().parent / "serve-update-feed.py"),
             "--directory", str(directory), "--seconds", str(seconds)],
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
        self.addCleanup(server.wait, 10)
        self.addCleanup(server.terminate)
        port = json.loads(server.stdout.readline())["port"]
        return f"http://127.0.0.1:{port}/"

    @staticmethod
    def bundle_version(app):
        with (Path(app) / "Contents" / "Info.plist").open("rb") as handle:
            return plistlib.load(handle)["CFBundleShortVersionString"]

    def installed_cli_version(self, app):
        completed = subprocess.run([str(Path(app) / "Contents" / "MacOS" / "playhouse-cli"), "version"],
                                   check=False, capture_output=True, text=True, timeout=30)
        self.assertEqual(completed.returncode, 0, completed.stderr)
        return json.loads(completed.stdout.splitlines()[-1])["result"]

    def wait_for_install_record(self, environment, timeout=90, cli=None):
        record = {}

        def finished():
            status = self.assert_success(self.call_cli("update", "status", extra_environment=environment, cli=cli)[0])
            record.update(status.get("lastInstall") or {})
            return bool(record)
        self.wait_for(finished, "The installer did not record a result.", timeout=timeout)
        return record

    # case-contract: test_update_check_offers_signed_release_on_release_builds | A development build reports the development phase and refuses to check, download or install, and its Check for Updates menu item is disabled, so it never updates itself. A stable build checks the signed release feed: before a check it is up to date with no offer; a check offers the newer release with its version, release date and notes, shown as a compact Update button at the trailing end of the window's title bar whose tooltip names them, which a fresh read still reports, and finds it through the release's asset list (GitHub's latest-release API) when the feed link fails; the window's check at every launch reaches the feed even within a day, and with the feed gone fails quietly, keeping the offer and the Update button with no error, while the hourly automatic check does not reach the feed again within a day, and a manual check from the app menu then reports the failure; a newer release published within the day is missed by the hourly check but offered at the next launch, where the Update button names it. Update checks can't be turned off: Settings has no daily-check toggle. A newer release built for another architecture or needing a newer macOS is not offered. An app in a folder it can't write to says to move Playhouse to Applications, refuses to check, and doesn't offer even a release it already found, so no update button shows.
    def test_update_check_offers_signed_release_on_release_builds(self):
        development = self.assert_success(self.call_cli("update", "status")[0])
        self.assertEqual(development["phase"], "development")
        self.assertEqual(development["channel"], "development")
        self.assertIsNone(development.get("available"))
        for command in (("check",), ("download",), ("install",)):
            self.assert_failure(self.call_cli("update", *command, expected_status=1)[0], "development_build")

        fixture, environment = self.make_update_fixture()
        before = self.assert_success(self.call_cli("update", "status", extra_environment=environment)[0])
        self.assertEqual((before["channel"], before["currentVersion"], before["phase"]), ("stable", "0.1.0", "upToDate"))
        self.assertIsNone(before.get("lastCheckedAt"))
        self.assertNotIn("autoCheck", before, "Update checks can't be turned off.")
        self.assert_failure(self.call_cli("update", "set-auto-check", "off", expected_status=2, extra_environment=environment)[0], "invalid_argument")
        self.assert_failure(
            self.call_cli("update", "check", "--automatic", "true", "--at-launch", "true", expected_status=2, extra_environment=environment)[0],
            "invalid_argument",
        )

        checked = self.assert_success(self.call_cli("update", "check", extra_environment=environment)[0])
        self.assertEqual(checked["phase"], "available")
        self.assertEqual(checked["available"]["version"], "0.2.0")
        self.assertEqual(checked["available"]["notes"], "Faster boards and a new update button.")
        self.assertEqual((checked["available"]["publishedAt"], checked["available"]["architecture"]), ("2026-11-18T00:00:00Z", "arm64"))
        self.assertIsNotNone(checked["lastCheckedAt"])
        reread = self.assert_success(self.call_cli("update", "status", extra_environment=environment)[0])
        self.assertEqual((reread["phase"], reread["available"]["version"]), ("available", "0.2.0"))
        # When the feed link fails, the release's asset list (GitHub's latest-release API) still finds it.
        broken_link = {**environment, "PLAYHOUSE_E2E_UPDATE_FEED_URL": fixture["feedURL"].replace("playhouse-release.json", "missing.json")}
        checked = self.assert_success(self.call_cli("update", "check", extra_environment=broken_link)[0])
        self.assertEqual((checked["phase"], checked["available"]["version"]), ("available", "0.2.0"))
        self.assertIsNone(checked.get("error"))

        # The automatic check ran less than a day ago, so it doesn't reach the feed.
        manifest = Path(fixture["feed"]) / "playhouse-release.json"
        signed_manifest = manifest.read_bytes()
        manifest.unlink()
        # Move the last check an hour back, still within the day, so a check that reaches the
        # feed visibly records a newer time (times are stored to the second).
        state = self.data_directory / "Updates" / "state.json"
        stored = json.loads(state.read_text(encoding="utf-8"))
        an_hour_ago = datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(hours=1)
        stored["lastCheckedAt"] = an_hour_ago.strftime("%Y-%m-%dT%H:%M:%SZ")
        state.write_text(json.dumps(stored), encoding="utf-8")
        automatic = self.assert_success(self.call_cli("update", "check", "--automatic", "true", extra_environment=environment)[0])
        self.assertEqual((automatic["phase"], automatic["lastCheckedAt"]), ("available", stored["lastCheckedAt"]))
        # The window's check at launch reaches the feed even within the day, so with the feed
        # gone it fails, but quietly: the offer stays and no error is recorded.
        self.assert_failure(
            self.call_cli("update", "check", "--at-launch", "true", expected_status=1, extra_environment=environment)[0],
            "update_unreachable",
        )
        launched = self.assert_success(self.call_cli("update", "status", extra_environment=environment)[0])
        self.assertNotEqual(launched["lastCheckedAt"], stored["lastCheckedAt"], "The check at launch should reach the feed within the day.")
        self.assertEqual((launched["phase"], launched["available"]["version"]), ("available", "0.2.0"))
        self.assertIsNone(launched.get("error"), "A failed check at launch must stay quiet.")
        self.call_cli("update", "check", expected_status=1, extra_environment=environment)
        failed = self.assert_success(self.call_cli("update", "status", extra_environment=environment)[0])
        self.assertEqual(failed["phase"], "failed")
        self.assertTrue(failed["error"])

        # A newer release published within the day: the hourly check misses it, the next launch offers it.
        _, newer = self.make_update_fixture(root="update-fixture-newer", release="0.3.0")
        hourly = self.assert_success(self.call_cli("update", "check", "--automatic", "true", extra_environment=newer)[0])
        self.assertEqual(hourly["available"]["version"], "0.2.0", "The hourly check must not reach the feed within the day.")
        relaunched = self.assert_success(self.call_cli("update", "check", "--at-launch", "true", extra_environment=newer)[0])
        self.assertEqual((relaunched["phase"], relaunched["available"]["version"]), ("available", "0.3.0"))
        self.assertIsNone(relaunched.get("error"))

        # A newer release this Mac can't run is not offered.
        for name, release in (("intel", {"architecture": "x86_64"}), ("future-macos", {"minimum_system": "99.0"})):
            with self.subTest(release=name):
                state.write_text(json.dumps({}), encoding="utf-8")
                _, other = self.make_update_fixture(root=f"update-fixture-{name}", **release)
                unsupported = self.assert_success(self.call_cli("update", "check", extra_environment=other)[0])
                self.assertEqual(unsupported["phase"], "upToDate", unsupported)
                self.assertIsNone(unsupported.get("available"))
                self.assertIsNotNone(unsupported["lastCheckedAt"])

        # An app in a folder it can't write to, as when run from a disk image, can't replace itself,
        # so even a release it already found isn't offered.
        manifest.write_bytes(signed_manifest)
        self.assertEqual(self.assert_success(self.call_cli("update", "check", extra_environment=environment)[0])["phase"], "available")
        installed_folder = Path(fixture["installedApp"]).parent
        installed_folder.chmod(0o555)
        try:
            misplaced = self.assert_success(self.call_cli("update", "status", extra_environment=environment)[0])
            self.assertEqual(misplaced["phase"], "misplaced")
            self.assertEqual(misplaced["error"], "Move Playhouse to Applications to receive updates.")
            self.assertIsNone(misplaced.get("available"))
            response, _ = self.call_cli("update", "check", expected_status=1, extra_environment=environment)
            self.assert_failure(response, "update_location")
            self.assertIn("Move Playhouse to Applications", response["error"]["message"])
        finally:
            installed_folder.chmod(0o755)
        self.assertEqual(self.assert_success(self.call_cli("update", "status", extra_environment=environment)[0])["phase"], "available")

    # case-contract: test_update_rejects_tampered_release | A release whose manifest is signed by another key is refused at check time, so nothing is offered and the failure is shown with the signature reason. A release whose archive grew after signing is offered but refused at download for its size, and one with a changed byte of the same size is refused for its checksum: each time nothing is staged beside the installed app, the failure is shown with its reason, installing reports there is nothing ready, and the installed app is untouched.
    def test_update_rejects_tampered_release(self):
        fixture, environment = self.make_update_fixture(tamper="signature")
        response, _ = self.call_cli("update", "check", expected_status=1, extra_environment=environment)
        self.assert_failure(response, "update_rejected")
        self.assertIn("signature", response["error"]["message"].lower())
        status = self.assert_success(self.call_cli("update", "status", extra_environment=environment)[0])
        self.assertEqual(status["phase"], "failed")
        self.assertIn("signature", status["error"].lower())
        self.assertIsNone(status.get("available"))

        for tamper, reason in (("archive", "bytes"), ("checksum", "checksum")):
            with self.subTest(tamper=tamper):
                shutil.rmtree(self.data_directory / "Updates")
                fixture, environment = self.make_update_fixture(tamper=tamper)
                self.assertEqual(self.assert_success(self.call_cli("update", "check", extra_environment=environment)[0])["phase"], "available")
                response, _ = self.call_cli("update", "download", expected_status=1, extra_environment=environment)
                self.assert_failure(response, "update_rejected")
                self.assertIn(reason, response["error"]["message"])
                status = self.assert_success(self.call_cli("update", "status", extra_environment=environment)[0])
                self.assertEqual(status["phase"], "failed")
                self.assertIn(reason, status["error"])
                self.assertEqual(status["available"]["version"], "0.2.0")
                installed = Path(fixture["installedApp"])
                self.assertFalse((installed.parent / ".Playhouse.app.update").exists(), "A refused download must not be staged.")
                self.assert_failure(self.call_cli("update", "install", expected_status=1, extra_environment=environment)[0], "no_update")
                self.assertEqual(self.bundle_version(installed), "0.1.0")

    # case-contract: test_update_download_reports_progress_and_cancels | Downloading a checked release from a feed served over HTTP reports its progress while it runs, rising to the whole archive, and a second download meanwhile is refused as busy. Canceling stops it, keeps the release offered without a failure, and leaves nothing staged or half-downloaded; canceling with no download running is refused. A check when the feed is gone is reported as unreachable and shown as a failed update that keeps the release offered. Retrying once the feed is back downloads and stages the release with progress rising to the whole archive, and a half-written message then holds the restart: it waits to restart into the staged release while the installed app stays the old version.
    def test_update_download_reports_progress_and_cancels(self):
        fixture, environment = self.make_update_fixture(served_seconds=8)
        installed = Path(fixture["installedApp"])
        staged = installed.parent / ".Playhouse.app.update"
        self.assertTrue(fixture["feedURL"].startswith("http://127.0.0.1:"), fixture)
        self.assertEqual(self.assert_success(self.call_cli("update", "check", extra_environment=environment)[0])["phase"], "available")
        self.assert_failure(self.call_cli("update", "cancel", expected_status=1, extra_environment=environment)[0], "no_download")

        # The download reports how far it got while it runs; canceling stops it and keeps the offer.
        downloader = self.start_cli("update", "download", extra_environment=environment)
        downloading = self.wait_for(
            lambda: (lambda status: status if status["phase"] == "downloading" and status.get("progress", 0) > 0 else None)(
                self.assert_success(self.call_cli("update", "status", extra_environment=environment)[0])),
            "The download should report progress.")
        self.assertLess(downloading["progress"], 1)
        self.assert_failure(self.call_cli("update", "download", expected_status=1, extra_environment=environment)[0], "update_busy")
        canceled = self.assert_success(self.call_cli("update", "cancel", extra_environment=environment)[0])
        self.assertEqual(canceled["phase"], "available")
        response, events = self.finish_cli(downloader, "update download", expected_status=1, timeout=30)
        self.assert_failure(response, "update_cancelled")
        self.assertTrue([event for event in events if event.get("type") == "update_progress"], events)
        status = self.assert_success(self.call_cli("update", "status", extra_environment=environment)[0])
        self.assertEqual((status["phase"], status["available"]["version"]), ("available", "0.2.0"))
        self.assertIsNone(status.get("error"), "A canceled download isn't a failure.")
        self.assertFalse(staged.exists(), "A canceled download stages nothing.")
        self.assertFalse((self.data_directory / "Updates" / "download").exists())

        # A feed that isn't there is reported as unreachable, and the release stays offered to retry.
        manifest = Path(fixture["feed"]) / "playhouse-release.json"
        signed = manifest.read_bytes()
        manifest.unlink()
        response, _ = self.call_cli("update", "check", expected_status=1, extra_environment=environment)
        self.assert_failure(response, "update_unreachable")
        failed = self.assert_success(self.call_cli("update", "status", extra_environment=environment)[0])
        self.assertEqual((failed["phase"], failed["available"]["version"]), ("failed", "0.2.0"))
        self.assertTrue(failed["error"])

        # Retrying once the feed is back finishes, with progress rising to the whole archive;
        # a half-written message then holds the restart.
        manifest.write_bytes(signed)
        drafted = self.create_task("Update download waits for a draft")
        self.assertTrue(self.assert_success(self.call_cli("task", "draft", drafted["id"], "--text", "Half-written message")[0])["hasUnsentDraft"])
        response, events = self.call_cli("update", "download", extra_environment=environment, timeout=60)
        downloaded = self.assert_success(response)
        self.assertEqual(downloaded["phase"], "ready")
        self.assertIsNone(downloaded.get("error"))
        progress = [event["payload"]["progress"] for event in events if event.get("type") == "update_progress"]
        self.assertGreaterEqual(len(progress), 3, progress)
        self.assertEqual(progress, sorted(progress), progress)
        self.assertTrue(0 < progress[0] < 1 and progress[-1] == 1, progress)
        self.assertEqual(self.bundle_version(staged), "0.2.0")
        self.assert_failure(self.call_cli("update", "cancel", expected_status=1, extra_environment=environment)[0], "no_download")
        waiting = self.assert_success(self.call_cli("update", "install", "--when-idle", "true", extra_environment=environment)[0])
        self.assertFalse(waiting["started"], waiting)
        self.assertEqual((waiting["status"]["phase"], waiting["status"]["unsentDrafts"]), ("waiting", 1), waiting)
        self.assertEqual((self.bundle_version(staged), self.bundle_version(installed)), ("0.2.0", "0.1.0"))
        self.assertIsNone(self.assert_success(self.call_cli("update", "status", extra_environment=environment)[0]).get("lastInstall"))

    # case-contract: test_update_install_replaces_app_cli_and_daemon | Downloading a checked release reports progress and stages it beside the installed app, ready to restart. Installing swaps the whole bundle in place, so the app, its command-line tool and its bridge daemon are the new version; the running daemon is stopped and the next request starts a new one; the staged and previous copies are cleaned up; the app is told it was updated, with the release notes, until the notice is opened, which saves it as seen, or a day has passed; the offer is gone, and checking the same feed again reports it up to date.
    def test_update_install_replaces_app_cli_and_daemon(self):
        fixture, environment = self.make_update_fixture()
        installed = Path(fixture["installedApp"])
        self.assertEqual(self.assert_success(self.call_cli("update", "check", extra_environment=environment)[0])["phase"], "available")
        response, events = self.call_cli("update", "download", extra_environment=environment)
        downloaded = self.assert_success(response)
        self.assertEqual(downloaded["phase"], "ready")
        progress = [event["payload"]["progress"] for event in events if event.get("type") == "update_progress"]
        self.assertTrue(progress and progress[-1] == 1, f"The download should report progress up to 1: {events}")
        staged = installed.parent / ".Playhouse.app.update"
        self.assertEqual(self.bundle_version(staged), "0.2.0")
        self.assertEqual(self.bundle_version(installed), "0.1.0")

        daemon_before = self.assert_success(self.call_cli("status")[0])["processID"]
        started = self.assert_success(self.call_cli("update", "install", "--when-idle", "true", extra_environment=environment)[0])
        self.assertTrue(started["started"], started)
        self.assertEqual(started["status"]["phase"], "installing")
        record = self.wait_for_install_record(environment)
        self.assertEqual((record["status"], record["fromVersion"], record["toVersion"]), ("installed", "0.1.0", "0.2.0"), record)
        self.assertFalse(record["acknowledged"])

        self.assertEqual(self.bundle_version(installed), "0.2.0")
        reported = self.installed_cli_version(installed)
        self.assertEqual((reported["version"], reported["channel"]), ("0.2.0", "stable"))
        daemon = installed / "Contents" / "MacOS" / "playhouse-daemon"
        self.assertTrue(os.access(daemon, os.X_OK))
        self.assertEqual(subprocess.run(["codesign", "--verify", "--strict", "--deep", str(installed)], capture_output=True).returncode, 0)
        self.assertFalse(staged.exists(), "The staged copy should be gone after the swap.")
        self.assertFalse((installed.parent / ".Playhouse.app.previous").exists(), "The previous version should be removed once the new one passes.")
        self.assertIn("installed", (self.data_directory / "Updates" / "Updater.log").read_text(encoding="utf-8"))
        self.assertFalse(self.process_is_running(daemon_before), "The installer should stop the old bridge daemon.")
        self.assertNotEqual(self.assert_success(self.call_cli("status")[0])["processID"], daemon_before)

        first = self.assert_success(self.call_cli("update", "launched", extra_environment=environment)[0])
        self.assertEqual(first["lastInstall"]["status"], "installed")
        self.assertEqual(first["lastInstall"]["notes"], "Faster boards and a new update button.")
        self.assertEqual((first["phase"], first["currentVersion"]), ("upToDate", "0.2.0"))
        self.assertIsNone(first.get("available"))
        # The notice stays until it is opened or a day has passed.
        relaunched = self.assert_success(self.call_cli("update", "launched", extra_environment=environment)[0])
        self.assertEqual((relaunched["lastInstall"]["toVersion"], relaunched["lastInstall"]["notes"]),
                         ("0.2.0", "Faster boards and a new update button."))
        dismissed = self.assert_success(self.call_cli("update", "dismiss-notice", extra_environment=environment)[0])
        self.assertTrue(dismissed["lastInstall"]["acknowledged"])
        self.assertIsNone(self.assert_success(self.call_cli("update", "launched", extra_environment=environment)[0]).get("lastInstall"),
                          "An opened notice isn't shown again.")
        record_file = self.data_directory / "Updates" / "last-install.json"
        saved = json.loads(record_file.read_text(encoding="utf-8"))
        saved["acknowledged"] = False
        saved["finishedAt"] = "2026-01-01T00:00:00Z"
        record_file.write_text(json.dumps(saved), encoding="utf-8")
        self.assertIsNone(self.assert_success(self.call_cli("update", "launched", extra_environment=environment)[0]).get("lastInstall"),
                          "A notice older than a day isn't shown.")
        again = self.assert_success(self.call_cli("update", "check", extra_environment=environment)[0])
        self.assertEqual(again["phase"], "upToDate")
        self.assertIsNone(again.get("available"))

    # case-contract: test_update_notice_keeps_notes_from_older_installer | An update started by a version that didn't keep the release it was installing still shows its notes: when the new version reports its launch before the installer has recorded a result, it keeps the offered release, so after its launch check finds nothing newer and clears the offer and the installer then records the install, the Updated notice carries the release's notes and What's new shows them.
    def test_update_notice_keeps_notes_from_older_installer(self):
        fixture, environment = self.make_update_fixture()
        self.assertEqual(self.assert_success(self.call_cli("update", "check", extra_environment=environment)[0])["phase"], "available")
        self.assertEqual(self.assert_success(self.call_cli("update", "download", extra_environment=environment)[0])["phase"], "ready")
        self.assertTrue(self.assert_success(self.call_cli("update", "install", extra_environment=environment)[0])["started"])
        self.assertEqual(self.wait_for_install_record(environment)["status"], "installed")
        # Recreate a relaunch after an install that an older version started: the installer
        # hasn't recorded a result yet, and the state doesn't name the release being installed.
        updates = self.data_directory / "Updates"
        record_file = updates / "last-install.json"
        held_record = record_file.read_text(encoding="utf-8")
        record_file.unlink()
        state_file = updates / "state.json"
        state = json.loads(state_file.read_text(encoding="utf-8"))
        self.assertEqual(state.pop("installing")["version"], "0.2.0", "The installing version keeps the release it installs.")
        state_file.write_text(json.dumps(state), encoding="utf-8")

        first = self.assert_success(self.call_cli("update", "launched", extra_environment=environment)[0])
        self.assertIsNone(first.get("lastInstall"), "Nothing is recorded before the installer finishes.")
        launch_check = self.assert_success(self.call_cli("update", "check", "--at-launch", "true", extra_environment=environment)[0])
        self.assertIsNone(launch_check.get("available"), "The launch check finds nothing newer than 0.2.0 and clears the offer.")
        record_file.write_text(held_record, encoding="utf-8")
        launched = self.assert_success(self.call_cli("update", "launched", extra_environment=environment)[0])
        self.assertEqual((launched["lastInstall"]["status"], launched["lastInstall"]["toVersion"], launched["lastInstall"]["notes"]),
                         ("installed", "0.2.0", "Faster boards and a new update button."), launched)

    # case-contract: test_update_install_rolls_back_broken_release | A release whose bridge daemon doesn't run passes download verification but fails the installer's health check after the swap, so the installer puts the previous version back: the installed app, command-line tool and daemon are the old version again, nothing is left staged, and the app is told that the update didn't install and why until that is dismissed, while the release stays offered. A release whose command-line tool doesn't run can't start its own installer, so the install is reported as failed until dismissed and the installed app is untouched.
    def test_update_install_rolls_back_broken_release(self):
        fixture, environment = self.make_update_fixture(tamper="broken")
        installed = Path(fixture["installedApp"])
        self.assert_success(self.call_cli("update", "check", extra_environment=environment)[0])
        self.assertEqual(self.assert_success(self.call_cli("update", "download", extra_environment=environment)[0])["phase"], "ready")
        self.assertTrue(self.assert_success(self.call_cli("update", "install", extra_environment=environment)[0])["started"])
        record = self.wait_for_install_record(environment)
        self.assertEqual((record["status"], record["fromVersion"], record["toVersion"]), ("rolledBack", "0.1.0", "0.2.0"), record)
        self.assertIn("bridge daemon", record["message"])

        self.assertEqual(self.bundle_version(installed), "0.1.0")
        self.assertEqual(self.installed_cli_version(installed)["version"], "0.1.0")
        self.assertFalse((installed.parent / ".Playhouse.app.update").exists())
        self.assertFalse((installed.parent / ".Playhouse.app.previous").exists())
        self.assertIn("rolling back", (self.data_directory / "Updates" / "Updater.log").read_text(encoding="utf-8"))

        launched = self.assert_success(self.call_cli("update", "launched", extra_environment=environment)[0])
        self.assertEqual(launched["lastInstall"]["status"], "rolledBack")
        self.assertEqual((launched["currentVersion"], launched["available"]["version"]), ("0.1.0", "0.2.0"))
        self.assert_success(self.call_cli("update", "dismiss-notice", extra_environment=environment)[0])
        self.assertIsNone(self.assert_success(self.call_cli("update", "launched", extra_environment=environment)[0]).get("lastInstall"),
                          "A dismissed failure isn't shown again.")

        shutil.rmtree(self.data_directory / "Updates")
        fixture, environment = self.make_update_fixture(tamper="installer")
        installed = Path(fixture["installedApp"])
        self.assert_success(self.call_cli("update", "check", extra_environment=environment)[0])
        self.assertEqual(self.assert_success(self.call_cli("update", "download", extra_environment=environment)[0])["phase"], "ready")
        self.assertTrue(self.assert_success(self.call_cli("update", "install", extra_environment=environment)[0])["started"])
        record = self.wait_for_install_record(environment)
        self.assertEqual((record["status"], record["fromVersion"], record["toVersion"]), ("failed", "0.1.0", "0.2.0"), record)
        self.assertIn("installer", record["message"])
        self.assertEqual(self.bundle_version(installed), "0.1.0")
        self.assertEqual(self.installed_cli_version(installed)["version"], "0.1.0")
        self.assertFalse((installed.parent / ".Playhouse.app.previous").exists())
        launched = self.assert_success(self.call_cli("update", "launched", extra_environment=environment)[0])
        self.assertEqual(launched["lastInstall"]["status"], "failed")
        self.assertEqual(launched["currentVersion"], "0.1.0")
        self.assertEqual(self.assert_success(self.call_cli("update", "launched", extra_environment=environment)[0])["lastInstall"]["status"], "failed",
                         "The failure is shown until it is dismissed.")
        self.assert_success(self.call_cli("update", "dismiss-notice", extra_environment=environment)[0])
        self.assertIsNone(self.assert_success(self.call_cli("update", "launched", extra_environment=environment)[0]).get("lastInstall"),
                          "A dismissed failure isn't shown again.")

    # case-contract: test_update_waits_for_running_agents_before_installing | While an agent is running a turn and a message typed in another task is unsent, installing a downloaded release once agents are idle doesn't start the installer: it reports one running agent and one message being written, the update is saved as waiting with Restart to update and a tooltip giving both reasons, and the installed app stays the old version. A task's unsent description that was never typed in the composer doesn't hold it. When the turn finishes the half-written message still holds the install; once it is cleared, the daemon installs the release by itself without another request, the turn's answer is kept once, and the installed app and its command-line tool are the new version.
    def test_update_waits_for_running_agents_before_installing(self):
        executable = self.install_provider_fixture("claude", "claude-fixture-reattach-update")
        fixture, environment = self.make_update_fixture()
        installed = Path(fixture["installedApp"])
        environment["PLAYHOUSE_E2E_CLAUDE_EXECUTABLE"] = str(executable)
        task = self.create_task("Update waits for agents", provider="claude")
        self.assertEqual(self.assert_success(self.call_cli("update", "check", extra_environment=environment)[0])["phase"], "available")
        self.assertEqual(self.assert_success(self.call_cli("update", "download", extra_environment=environment)[0])["phase"], "ready")

        sender = self.start_cli("conversation", "send", task["id"], "--message", "Keep working while an update waits.", extra_environment=environment)
        self.wait_for(Path(str(executable) + ".reattach-ready").is_file, "The turn should be running.")
        self.wait_for(lambda: self.assert_success(self.call_cli("conversation", "runtime", extra_environment=environment)[0])["activeThreadIDs"],
                      "The turn is active.")
        # A message typed in another task but not sent holds the install too.
        drafted = self.create_task("Update waits for drafts")
        self.assertTrue(self.assert_success(self.call_cli("task", "draft", drafted["id"], "--text", "Half-written message")[0])["hasUnsentDraft"])
        waiting = self.assert_success(self.call_cli("update", "install", "--when-idle", "true", extra_environment=environment)[0])
        self.assertFalse(waiting["started"], waiting)
        self.assertEqual((waiting["activeTurns"], waiting["unsentDrafts"]), (1, 1), waiting)
        self.assertEqual((waiting["status"]["phase"], waiting["status"]["activeTurns"], waiting["status"]["unsentDrafts"]), ("waiting", 1, 1))
        # Longer than the daemon's idle check: it keeps waiting while the agent works.
        time.sleep(3)
        status = self.assert_success(self.call_cli("update", "status", extra_environment=environment)[0])
        self.assertEqual((status["phase"], status["activeTurns"]), ("waiting", 1))
        self.assertIsNone(status.get("lastInstall"))
        self.assertEqual(self.bundle_version(installed), "0.1.0")
        self.assertEqual(self.bundle_version(installed.parent / ".Playhouse.app.update"), "0.2.0")

        Path(str(executable) + ".reattach-release").touch()
        sent, _ = self.finish_cli(sender, "conversation send", timeout=60)
        self.assert_success(sent)
        # The turn is over, but the unsent message still holds the install.
        self.wait_for(lambda: self.assert_success(self.call_cli("update", "status", extra_environment=environment)[0]).get("activeTurns") == 0,
                      "The finished turn no longer holds the install.")
        time.sleep(3)
        status = self.assert_success(self.call_cli("update", "status", extra_environment=environment)[0])
        self.assertEqual((status["phase"], status["activeTurns"], status["unsentDrafts"]), ("waiting", 0, 1), status)
        self.assertEqual(self.bundle_version(installed), "0.1.0")
        self.assertFalse(self.assert_success(self.call_cli("task", "draft", drafted["id"], "--text", "")[0])["hasUnsentDraft"])
        # Nothing asks again: the daemon installs once nothing holds it.
        record = self.wait_for_install_record(environment)
        self.assertEqual((record["status"], record["fromVersion"], record["toVersion"]), ("installed", "0.1.0", "0.2.0"), record)
        self.assertEqual(self.bundle_version(installed), "0.2.0")
        self.assertEqual(self.installed_cli_version(installed)["version"], "0.2.0")
        self.assertIn("update.install_when_idle", (self.data_directory / "Diagnostics.jsonl").read_text(encoding="utf-8"))
        texts, _ = self.history_texts(task["id"], environment)
        self.assertEqual(texts.count("After restart."), 1, texts)
        after = self.assert_success(self.call_cli("update", "status", extra_environment=environment)[0])
        self.assertNotEqual(after["phase"], "waiting")
        self.assertIsNone(after.get("activeTurns"))

    # case-contract: test_update_installs_over_its_own_app_and_daemon | The installed app's own command-line tool accepts its bundle with verify-bundle and refuses a copy changed after signing. Updating the app a request comes from, with no test target, stops that app's own bridge daemon on its private service and installs over it, so the app, its command-line tool and the next daemon on that service report the new version; a daemon another service started from the old bundle reports that it was replaced on disk and is retired by the next request, which starts one from the new bundle (the visible suite's sandboxed runner can't start a daemon itself, so only the headless suite starts one on another service). With the app's window running, the installer asks it to quit, the app quits by itself rather than being stopped, and the installer reopens the new version in the same data folder and bridge service, where it says it was updated and its What's new shows the release's notes, although its launch check found nothing newer and cleared the offer before the installer recorded the result; the headless suite runs no window, so nothing is reopened, and it makes that launch check from the command line before reading the notice.
    def test_update_installs_over_its_own_app_and_daemon(self):
        fixture, environment = self.make_update_fixture()
        installed = Path(fixture["installedApp"])
        own_cli = installed / "Contents" / "MacOS" / "playhouse-cli"
        # No test target: the update replaces the bundle the request comes from.
        del environment["PLAYHOUSE_E2E_UPDATE_TARGET_APP"]
        environment["PLAYHOUSE_BRIDGE_SERVICE_NAME"] = f"{arguments.service_name}.self-update-{uuid.uuid4().hex[:8]}"
        other = {"PLAYHOUSE_BRIDGE_SERVICE_NAME": f"{arguments.service_name}.self-other-{uuid.uuid4().hex[:8]}"}
        try:
            verified = self.assert_success(self.call_cli("update", "verify-bundle", "--bundle", installed, "--version", "0.1.0", cli=own_cli)[0])
            self.assertEqual((verified["version"], verified["build"]), ("0.1.0", "100"))
            altered = self.data_directory / "altered" / "Playhouse.app"
            altered.parent.mkdir()
            subprocess.run(["ditto", str(installed), str(altered)], check=True)
            (altered / "Contents" / "Resources" / "added-after-signing.txt").write_text("changed", encoding="utf-8")
            self.assert_failure(self.call_cli("update", "verify-bundle", "--bundle", altered, expected_status=1, cli=own_cli)[0], "update_rejected")

            self.assert_success(self.call_cli("status", extra_environment=environment, cli=own_cli)[0])
            before = self.assert_success(self.call_cli("daemon", "info", extra_environment=environment, cli=own_cli)[0])
            self.assertEqual((before["running"], before["appVersion"], before["replacedOnDisk"]), (True, "0.1.0", False), before)
            self.assertTrue(Path(before["executablePath"]).resolve().is_relative_to(installed.resolve()), before)
            old_other = self.assert_success(self.call_cli("status", extra_environment=other, cli=own_cli)[0])["processID"]

            self.assertEqual(self.assert_success(self.call_cli("update", "check", extra_environment=environment, cli=own_cli)[0])["phase"], "available")
            self.assertEqual(self.assert_success(self.call_cli("update", "download", extra_environment=environment, cli=own_cli)[0])["phase"], "ready")
            self.assertTrue(self.assert_success(self.call_cli("update", "install", extra_environment=environment, cli=own_cli)[0])["started"])
            record = self.wait_for_install_record(environment, cli=own_cli)
            self.assertEqual((record["status"], record["fromVersion"], record["toVersion"]), ("installed", "0.1.0", "0.2.0"), record)
            self.assertEqual(self.bundle_version(installed), "0.2.0")
            self.assertEqual(self.installed_cli_version(installed)["version"], "0.2.0")
            log = (self.data_directory / "Updates" / "Updater.log").read_text(encoding="utf-8")
            self.assertIn(f"stopping the bridge daemon ({before['processID']})", log)
            self.assertNotIn("opening", log, "With no window running, nothing is reopened.")
            self.assertFalse(self.process_is_running(before["processID"]), "The installer stops the daemon of the app it replaces.")
            after = self.assert_success(self.call_cli("daemon", "info", extra_environment=environment, cli=own_cli)[0])
            self.assertEqual((after["appVersion"], after["replacedOnDisk"]), ("0.2.0", False), after)
            # A reopened window's launch check runs before the installer records the result,
            # finds nothing newer and clears the offer; the notice still has the notes.
            launch_check = self.assert_success(self.call_cli("update", "check", "--at-launch", "true", extra_environment=environment, cli=own_cli)[0])
            self.assertIsNone(launch_check.get("available"), launch_check)
            launched = self.assert_success(self.call_cli("update", "launched", extra_environment=environment, cli=own_cli)[0])
            self.assertEqual((launched["lastInstall"]["toVersion"], launched["lastInstall"]["notes"]),
                             ("0.2.0", "Faster boards and a new update button."), launched)

            # Started from the old bundle on another service, this daemon outlived the swap.
            stale = self.assert_success(self.call_cli("daemon", "info", extra_environment=other, cli=own_cli)[0])
            self.assertEqual((stale["processID"], stale["appVersion"], stale["replacedOnDisk"]), (old_other, "0.1.0", True), stale)
            fresh = self.assert_success(self.call_cli("status", extra_environment=other, cli=own_cli)[0])["processID"]
            self.assertNotEqual(fresh, old_other)
            self.wait_for(lambda: not self.process_is_running(old_other), "The replaced daemon retires itself.")
            self.assertEqual(self.assert_success(self.call_cli("daemon", "info", extra_environment=other, cli=own_cli)[0])["appVersion"], "0.2.0")
        finally:
            for service in (environment, other):
                self.call_cli("daemon", "shutdown", extra_environment=service, cli=own_cli)

    # case-contract: test_update_restart_now_keeps_claude_turn_running | Restarting to update while a Claude Code turn is running doesn't wait for it: with the update waiting for the agent, installing now starts the installer, a second install while it runs is refused as busy, and the installer stops the app's own bridge daemon and installs over it; with the window running, the app quits by itself when the installer asks rather than being stopped. The send that was waiting on the stopped daemon fails as unavailable, the Claude Code process keeps running, the next daemon is the new version and reattaches the same run; when that daemon is stopped in turn, it refuses new requests as exiting instead of dropping them and logs each one, gives up its socket before it exits so callers already queued on it are refused rather than dropped, and the daemon that follows starts only once it has exited, the CLI and the window's update check send them again to the daemon that follows (the headless suite runs no window, so only the CLI's are sent), and that daemon takes the same run back; and when the turn finishes its answer is kept once and the task settles through its outcome.
    def test_update_restart_now_keeps_claude_turn_running(self):
        self.assert_restart_now_keeps_turn_running("claude")

    # case-contract: test_update_restart_now_keeps_codex_turn_running | Restarting to update while a Codex turn is running doesn't wait for it: with the update waiting for the agent, installing now starts the installer, a second install while it runs is refused as busy, and the installer stops the app's own bridge daemon and installs over it; with the window running, the app quits by itself when the installer asks rather than being stopped. The send that was waiting on the stopped daemon fails as unavailable, the shared Codex app-server keeps running, the next daemon is the new version and reconnects to the same server; when that daemon is stopped in turn, it refuses new requests as exiting instead of dropping them and logs each one, gives up its socket before it exits so callers already queued on it are refused rather than dropped, and the daemon that follows starts only once it has exited, the CLI and the window's update check send them again to the daemon that follows (the headless suite runs no window, so only the CLI's are sent), and that daemon takes the same server back; and when the turn finishes its answer is kept once and the task settles through its outcome.
    def test_update_restart_now_keeps_codex_turn_running(self):
        self.assert_restart_now_keeps_turn_running("codex")

    def assert_daemon_exit_refuses_and_hands_over(self, environment, cli, daemon_pid, provider, agents):
        """While a daemon stops it refuses new requests as exiting rather than dropping them, the
        CLI sends them again to the daemon that follows, and that daemon takes the agent back once."""
        service = environment["PLAYHOUSE_BRIDGE_SERVICE_NAME"]
        log = self.bridge_socket(service).with_name(self.bridge_socket(service).name + ".log")
        # An open connection keeps the stopping daemon draining for its full two seconds.
        holder = self.open_bridge_connection(service)
        try:
            time.sleep(0.2)
            requested = log.read_text(encoding="utf-8").count("shutdown requested") if log.is_file() else 0
            released = log.read_text(encoding="utf-8").count("released the socket, exiting") if log.is_file() else 0
            stopper = self.start_cli("daemon", "shutdown", extra_environment=environment, cli=cli)
            self.wait_for(lambda: log.read_text(encoding="utf-8").count("shutdown requested") > requested,
                          "The daemon should log the shutdown request.")

            def refused():
                with self.open_bridge_connection(service) as probe:
                    response = self.raw_bridge_response(probe, "daemon.info")
                return response if response and (response.get("error") or {}).get("code") == "daemon_exiting" else None
            refusal = self.wait_for(refused, "A stopping daemon should refuse new requests as exiting.", timeout=1.5)
            self.assertFalse(refusal["ok"])
            self.assertIn("refused daemon.info: exiting", log.read_text(encoding="utf-8"), "The daemon logs the requests it refuses.")
            status = self.assert_success(self.call_cli("status", extra_environment=environment, cli=cli)[0])
        finally:
            holder.close()
        self.assertNotEqual(status["processID"], daemon_pid, "The refused request is answered by the next daemon.")
        self.assertTrue(self.wait_until_process_exits(daemon_pid, 25), "The stopped daemon exits.")
        log_text = log.read_text(encoding="utf-8")
        self.assertEqual(log_text.count("released the socket, exiting"), released + 1,
                         "The stopping daemon gives up its socket before it exits, so callers queued on it are refused rather than dropped.")
        self.assertGreater(log_text.rfind("listening at"), log_text.rfind("released the socket, exiting"),
                           "The next daemon starts only after the stopping daemon has exited.")
        response, _ = self.finish_cli(stopper, "daemon shutdown", timeout=30)
        self.assert_success(response)
        self.assertEqual([m["process"] for kind, _, m in self.agent_manifests() if kind == provider and m["serviceName"] == service], agents,
                         "The next daemon takes the same agent back.")
        self.assertTrue(self.agent_process_alive(agents[0]))

    def assert_restart_now_keeps_turn_running(self, provider):
        """Installs over the running app's own daemon while a provider turn is running on it."""
        executable = self.install_provider_fixture(provider, f"{provider}-fixture-reattach-restart")
        fixture, environment = self.make_update_fixture()
        installed = Path(fixture["installedApp"])
        own_cli = installed / "Contents" / "MacOS" / "playhouse-cli"
        del environment["PLAYHOUSE_E2E_UPDATE_TARGET_APP"]
        environment.update(self.restart_service_environment(provider, executable))
        if provider == "codex":
            environment["PLAYHOUSE_E2E_CODEX_SERVER_IDLE_SECONDS"] = "3"
        task = self.create_task(f"Restart now with {provider}", provider=provider)
        try:
            self.assertEqual(self.assert_success(self.call_cli("update", "check", extra_environment=environment, cli=own_cli)[0])["phase"], "available")
            self.assertEqual(self.assert_success(self.call_cli("update", "download", extra_environment=environment, cli=own_cli)[0])["phase"], "ready")
            sender = self.start_cli("conversation", "send", task["id"], "--message", "Keep working through the update.",
                                    extra_environment=environment, cli=own_cli)
            self.wait_for(Path(str(executable) + ".reattach-ready").is_file, "The turn should be running.")
            self.wait_for(lambda: self.assert_success(self.call_cli("conversation", "runtime", extra_environment=environment, cli=own_cli)[0])["activeThreadIDs"],
                          "The turn is active.")
            agents = [m["process"] for kind, _, m in self.agent_manifests()
                      if kind == provider and m["serviceName"] == environment["PLAYHOUSE_BRIDGE_SERVICE_NAME"]]
            self.assertEqual(len(agents), 1, "One agent process runs the turn.")
            daemon = self.assert_success(self.call_cli("daemon", "info", extra_environment=environment, cli=own_cli)[0])
            self.assertEqual(daemon["appVersion"], "0.1.0")

            waiting = self.assert_success(self.call_cli("update", "install", "--when-idle", "true", extra_environment=environment, cli=own_cli)[0])
            self.assertEqual((waiting["started"], waiting["status"]["phase"]), (False, "waiting"), waiting)
            # Restart to update: install now, without waiting for the agent.
            started = self.assert_success(self.call_cli("update", "install", extra_environment=environment, cli=own_cli)[0])
            self.assertTrue(started["started"], started)
            self.assert_failure(self.call_cli("update", "install", expected_status=1, extra_environment=environment, cli=own_cli)[0], "update_busy")
            record = self.wait_for_install_record(environment, cli=own_cli)
            self.assertEqual((record["status"], record["fromVersion"], record["toVersion"]), ("installed", "0.1.0", "0.2.0"), record)
            self.assertEqual(self.installed_cli_version(installed)["version"], "0.2.0")
            self.assertIn(f"stopping the bridge daemon ({daemon['processID']})",
                          (self.data_directory / "Updates" / "Updater.log").read_text(encoding="utf-8"))
            self.assertFalse(self.process_is_running(daemon["processID"]), "The installer stops the daemon running the turn.")
            sent, _ = self.finish_cli(sender, "conversation send", expected_status=69, timeout=30)
            self.assert_failure(sent, "service_unavailable")
            self.assertTrue(self.agent_process_alive(agents[0]), "The agent keeps working through the update.")

            new_daemon = self.wait_for(
                lambda: (lambda info: info if info["appVersion"] == "0.2.0" else None)(
                    self.assert_success(self.call_cli("daemon", "info", extra_environment=environment, cli=own_cli)[0])),
                "The next daemon is the new version.")
            self.assert_daemon_exit_refuses_and_hands_over(environment, own_cli, new_daemon["processID"], provider, agents)

            watcher = self.start_cli("conversation", "watch", task["id"], extra_environment=environment, cli=own_cli)
            self.assertEqual(self.task_for(task["id"], environment)["status"], "In Progress")
            self.assertEqual([m["process"] for kind, _, m in self.agent_manifests()
                              if kind == provider and m["serviceName"] == environment["PLAYHOUSE_BRIDGE_SERVICE_NAME"]], agents,
                             "The new daemon reattaches the same agent process.")
            Path(str(executable) + ".reattach-release").touch()
            response, events = self.finish_cli(watcher, "conversation watch", timeout=60)
            self.assertTrue(self.assert_success(response)["watched"])
            self.assertIn("completed", [event["type"] for event in events])
            final = self.wait_for(
                lambda: (lambda record: record if record["status"] != "In Progress" else None)(self.task_for(task["id"], environment)),
                "The turn settles through its outcome.")
            self.assertEqual(final["status"], "Waiting Response")
            self.assertNotIn("restarting", final.get("statusMessage") or "")
            texts, _ = self.history_texts(task["id"], environment)
            self.assertEqual("\n".join(texts).count("After restart."), 1, texts)
        finally:
            self.call_cli("daemon", "shutdown", extra_environment=environment, cli=own_cli)
            self.stop_surviving_agents()

