//
//  AppDelegate.swift
//  Clock Signal
//
//  Created by Thomas Harte on 16/07/2015.
//  Copyright 2015 Thomas Harte. All rights reserved.
//

import Cocoa

@NSApplicationMain
class AppDelegate: NSObject, NSApplicationDelegate {
	private struct FourADLaunchOptions {
		let mediaURL: URL?
		let artifactURL: URL?
		let quitAfterArtifact: Bool
	}

	private var hasLaunchedFourADCommandLine = false
	private lazy var fourADLaunchOptions: FourADLaunchOptions? = {
		return Self.parseFourADLaunchOptions(arguments: ProcessInfo.processInfo.arguments)
	}()

	func applicationDidFinishLaunching(_ notification: Notification) {
		if let romPath = Self.commandLineValue("--fourad-rom-path", arguments: ProcessInfo.processInfo.arguments) {
			let expanded = NSString(string: romPath).expandingTildeInPath
			CSSetFourADROMImagesRoot(expanded)
		}

		// Check for at least one Metal-capable GPU; this check
		// will become unnecessary if/when the minimum OS version
		// that this project supports reascends to 10.14.
		if MTLCopyAllDevices().isEmpty {
			let alert = NSAlert()
			alert.messageText = "This application requires a Metal-capable GPU."
			alert.addButton(withTitle: "Quit")
			alert.runModal()

			let application = notification.object as! NSApplication
			application.terminate(self)
		}

		DispatchQueue.main.async { [weak self] in
			_ = self?.launchFourADCommandLineIfNeeded()
		}
	}

	private var hasShownOpenDocument = false
	func applicationShouldRestoreApplicationState(_ app: NSApplication) -> Bool {
		return fourADLaunchOptions == nil
	}

	func applicationShouldSaveApplicationState(_ app: NSApplication) -> Bool {
		return fourADLaunchOptions == nil
	}

	func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
		if launchFourADCommandLineIfNeeded() || fourADLaunchOptions != nil {
			return false
		}

		// Decline to show the 'New...' selector by default; the 'Open...'
		// dialogue has already been shown if this application was started
		// without a file.
		//
		// Obiter: I dislike it when other applications do this for me, but it
		// seems to be the new norm, and I've had user feedback that showing
		// nothing is confusing. So here it is.
		if !hasShownOpenDocument {
			NSDocumentController.shared.openDocument(self)
			hasShownOpenDocument = true
		}
		return false
	}

	private static func commandLineValue(_ name: String, arguments: [String]) -> String? {
		for index in arguments.indices {
			let argument = arguments[index]
			if argument == name, index + 1 < arguments.count {
				return arguments[index + 1]
			}
			if argument.hasPrefix(name + "=") {
				return String(argument.dropFirst(name.count + 1))
			}
		}
		return nil
	}

	private static func hasFourADArgument(_ arguments: [String]) -> Bool {
		arguments.contains { argument in
			argument == "--fourad-fail-fast" ||
			argument == "--fourad-disk-snapshot" ||
			argument == "--fourad-quit-after-artifact" ||
			argument.hasPrefix("--fourad-")
		}
	}

	private static func parseFourADLaunchOptions(arguments: [String]) -> FourADLaunchOptions? {
		let hasFourADArguments = hasFourADArgument(arguments)
		if let machine = commandLineValue("--new", arguments: arguments), machine.lowercased() != "electron" {
			return nil
		}
		guard hasFourADArguments || commandLineValue("--new", arguments: arguments)?.lowercased() == "electron" else {
			return nil
		}

		var skipNext = false
		let knownValueArguments = Set([
			"--new",
			"--fourad-media",
			"--fourad-artifact-dir",
			"--fourad-boot-delay",
			"--fourad-boot-command",
			"--fourad-keys",
			"--fourad-script",
			"--fourad-rom-path",
		])

		var mediaURL: URL?
		if let mediaArgument = commandLineValue("--fourad-media", arguments: arguments) {
			let path = NSString(string: mediaArgument).expandingTildeInPath
			mediaURL = URL(fileURLWithPath: path)
		}
		for argument in arguments.dropFirst() {
			if skipNext {
				skipNext = false
				continue
			}
			if knownValueArguments.contains(argument) {
				skipNext = true
				continue
			}
			if argument.hasPrefix("--") {
				continue
			}
			if mediaURL == nil && (argument.lowercased().hasSuffix(".ssd") || argument.lowercased().hasSuffix(".dsd")) {
				let path = NSString(string: argument).expandingTildeInPath
				mediaURL = URL(fileURLWithPath: path)
			}
		}

		let artifactArgument = commandLineValue("--fourad-artifact-dir", arguments: arguments)
		let artifactURL = artifactArgument.map { URL(fileURLWithPath: NSString(string: $0).expandingTildeInPath) }
		return FourADLaunchOptions(
			mediaURL: mediaURL,
			artifactURL: artifactURL,
			quitAfterArtifact: arguments.contains("--fourad-quit-after-artifact"))
	}

	private func launchFourADCommandLineIfNeeded() -> Bool {
		guard !hasLaunchedFourADCommandLine, let options = fourADLaunchOptions else {
			return false
		}
		hasLaunchedFourADCommandLine = true
		hasShownOpenDocument = true

		writeFourADLaunchState("starting command-line Electron launch", options: options)
		do {
			let machineDocument = MachineDocument()
			NSDocumentController.shared.addDocument(machineDocument)
			machineDocument.makeWindowControllers()
			machineDocument.showWindows()
			let analyser = CSStaticAnalyser(electronDFS: true, adfs: false, ap6: false, sidewaysRAM: false)
			machineDocument.configureAs(analyser)
			if let mediaURL = options.mediaURL {
				machineDocument.insertFourADMedia(mediaURL)
			}
			writeFourADLaunchState("created Electron document and queued media", options: options)
			return true
		} catch {
			writeFourADLaunchState("command-line launch failed: \(error)", options: options)
			if options.quitAfterArtifact {
				NSApp.terminate(self)
			}
			return true
		}
	}

	private func writeFourADLaunchState(_ message: String, options: FourADLaunchOptions) {
		guard let artifactURL = options.artifactURL else {
			NSLog("4AD: \(message)")
			return
		}
		try? FileManager.default.createDirectory(at: artifactURL, withIntermediateDirectories: true, attributes: nil)
		let line = "\(Date()): \(message)\n"
		let logURL = artifactURL.appendingPathComponent("launcher-state.txt")
		if let data = line.data(using: .utf8) {
			if FileManager.default.fileExists(atPath: logURL.path), let handle = try? FileHandle(forWritingTo: logURL) {
				handle.seekToEndOfFile()
				handle.write(data)
				handle.closeFile()
			} else {
				try? data.write(to: logURL)
			}
		}
	}
}
