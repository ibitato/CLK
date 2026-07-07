//
//  MachineDocument.swift
//  Clock Signal
//
//  Created by Thomas Harte on 04/01/2016.
//  Copyright 2016 Thomas Harte. All rights reserved.
//

import AudioToolbox
import Cocoa
import QuartzCore
import System


class MachineDocument:
	NSDocument,
	NSWindowDelegate,
	CSMachineDelegate,
	CSScanTargetViewResponderDelegate,
	CSROMReciverViewDelegate
{
	// MARK: - Mutual Exclusion.

	/// Ensures exclusive access between calls to self.machine.run and close().
	private let actionLock = NSLock()
	/// Ensures exclusive access between calls to machine.updateView and machine.drawView, and close().
	private let drawLock = NSLock()

	// MARK: - Machine details.

	/// A description of the machine this document should represent once fully set up.
	private var machineDescription: CSStaticAnalyser?

	/// The active machine, following its successful creation.
	private var machine: CSMachine!

	private struct FourADArtifactOptions {
		let directory: URL
		let bootDelay: TimeInterval
		let bootCommand: String?
		let keys: [String]
		let scriptSteps: [FourADScriptStep]
		let quitAfterArtifact: Bool
		let failFast: Bool
		let diskSnapshot: Bool
	}

	private struct FourADScriptStep {
		let action: String
		let name: String
		let key: String?
		let text: String?
		let delay: TimeInterval
		let timeout: TimeInterval
		let snapshot: String?
		let expect: [String: Any]
	}

	private lazy var fourADAutoBoot: Bool = {
		ProcessInfo.processInfo.arguments.contains("--fourad-auto-boot")
	}()

	private lazy var fourADInteractiveBootCommand: String? = {
		Self.fourADArgumentValue("--fourad-boot-command", arguments: ProcessInfo.processInfo.arguments)
	}()

	private var fourADFailFastTimer: Timer?

	private lazy var fourADArtifactOptions: FourADArtifactOptions? = {
		return Self.parseFourADArtifactOptions(arguments: ProcessInfo.processInfo.arguments)
	}()
	private var fourADArtifactScheduled = false
	private var pendingFourADMediaURL: URL?
	private var fourADAutomationStepIndex = -1
	private var fourADAutomationStepName = ""
	private var fourADAutomationLastResult = ""

	/// @returns the appropriate window content aspect ratio for this @c self.machine.
	private var aspectRatio: NSSize {
		get {
			return NSSize(width: 4.0, height: 3.0)
		}
	}

	/// The output audio queue, if any.
	private var audioQueue: CSAudioQueue!

	// MARK: - Main NIB connections.

	/// The OpenGL view to receive this machine's display.
	@IBOutlet weak var scanTargetView: CSScanTargetView!

	/// The options view, if any.
	@IBOutlet var optionsView: NSView!
	@IBOutlet var optionsController: MachineController!

	/// The activity panel, if one is deemed appropriate.
	@IBOutlet var activityView: NSView!

	/// The volume view.
	@IBOutlet var volumeView: NSView!
	@IBOutlet var volumeSlider: NSSlider!

	// MARK: - NSDocument Overrides and NSWindowDelegate methods.

	/// Links this class to the MachineDocument NIB.
	override var windowNibName: NSNib.Name? {
		return "MachineDocument"
	}

	var fileObserver: CSFileContentChangeObserver?
	override func read(from url: URL, ofType typeName: String) throws {
		if let analyser = CSStaticAnalyser(fileAt: url) {
			checkPermisions(analyser.mediaSet)
			self.displayName = analyser.displayName
			self.configureAs(analyser)

			self.fileObserver = CSFileContentChangeObserver.init(url: url, handler: {
				if let machine = self.machine {
					DispatchQueue.main.async { [weak self] in
						guard let self = self else {
							return
						}
						switch machine.effectForFile(atURLDidChange: url) {
							case .reinsertMedia:	self.insertFile(url)
							case .restartMachine:
								let target = CSStaticAnalyser(fileAt: url)
								if let target = target {
									self.audioQueue = nil
									machine.substitute(target)
									self.optionsController?.establishStoredOptions()
								}

							case .none:				fallthrough
							@unknown default:		break
						}
					}
				}
			})
		} else {
			throw NSError(domain: "MachineDocument", code: -1, userInfo: nil)
		}
	}

	override func close() {
		// Close any dangling sheets.
		//
		// Be warned: in 11.0 at least, if there are any panels then posting the endSheet request
		// will defer the close(), and close() will be called again at the end of that animation.
		//
		// So: MAKE SURE IT'S SAFE TO ENTER THIS FUNCTION TWICE. Hence the non-assumption here about
		// any windows still existing.
		if let window = self.windowControllers.first?.window {
			for sheet in window.sheets {
				window.endSheet(sheet)
			}
		}

		// Stop the machine, if any.
		machine?.stop()

		// End the update cycle.
		actionLock.lock()
		drawLock.lock()
		machine = nil
		scanTargetView.invalidate()
		actionLock.unlock()
		drawLock.unlock()

		// Let the document controller do its thing.
		super.close()
	}

	override func data(ofType typeName: String) throws -> Data {
		throw NSError(domain: NSOSStatusErrorDomain, code: unimpErr, userInfo: nil)
	}

	override func windowControllerDidLoadNib(_ aController: NSWindowController) {
		super.windowControllerDidLoadNib(aController)
		aController.window?.contentAspectRatio = self.aspectRatio
		volumeSlider.floatValue = pow(2.0, userDefaultsVolume())

		volumeView.layer!.cornerRadius = 5.0
		scanTargetView.responderDelegate = self
	}

	private var missingROMs: String = ""
	func configureAs(_ analysis: CSStaticAnalyser) {
		self.machineDescription = analysis

		actionLock.lock()
		drawLock.lock()

		let missingROMs = NSMutableString()
		if let machine = CSMachine(analyser: analysis, missingROMs: missingROMs) {
			setRomRequesterIsVisible(false)

			self.machine = machine
			machine.setVolume(userDefaultsVolume())
			setupMachineOutput()
		} else {
			self.missingROMs = missingROMs as String
			requestRoms()
		}

		actionLock.unlock()
		drawLock.unlock()
	}

	enum InteractionMode {
		case notStarted, showingMachinePicker, showingROMRequester, showingMachine
	}
	private var interactionMode: InteractionMode = .notStarted

	// Attempting to show a sheet before the window is visible (such as when the NIB is loaded) results in
	// a sheet mysteriously floating on its own. For now, use windowDidUpdate as a proxy to check whether
	// the window is visible.
	func windowDidUpdate(_ notification: Notification) {
		if self.windowControllers.count > 0, let window = self.windowControllers[0].window, window.isVisible {
			// Grab the regular window title, if it's not already stored.
			if self.unadornedWindowTitle == "" {
				self.unadornedWindowTitle = window.title
			}
			updateWindowTitle()

			// If an interaction mode is not yet in effect, pick the proper one and display the relevant thing.
			if self.interactionMode == .notStarted {
				// If a full machine exists, just continue showing it.
				if self.machine != nil {
					self.interactionMode = .showingMachine
					setupMachineOutput()
					return
				}

				// If a machine has been picked but is not showing, there must be ROMs missing.
				if self.machineDescription != nil {
					self.interactionMode = .showingROMRequester
					requestRoms()
					return
				}

				// If a machine hasn't even been picked yet, show the machine picker.
				self.interactionMode = .showingMachinePicker
				Bundle.main.loadNibNamed("MachinePicker", owner: self, topLevelObjects: nil)
				self.machinePicker?.establishStoredOptions()
				window.beginSheet(self.machinePickerPanel!, completionHandler: nil)
			}
		}
	}

	func windowDidEnterFullScreen(_ notification: Notification) {
		updateActivityViewVisibility()
	}

	// MARK: - Connections Between Machine and the Outside World.

	private func setupMachineOutput() {
		if let machine = self.machine, let scanTargetView = self.scanTargetView, machine.view != scanTargetView {
			// Establish the output aspect ratio and audio.
			let aspectRatio = self.aspectRatio
			machine.setView(scanTargetView, aspectRatio: Float(aspectRatio.width / aspectRatio.height))

			// Attach an options panel if one is available.
			if let optionsNibName = self.machineDescription?.optionsNibName {
				let didLoad = Bundle.main.loadNibNamed(optionsNibName, owner: self, topLevelObjects: nil)
				assert(didLoad)

				if let optionsController = self.optionsController {
					optionsController.machine = machine
					optionsController.establishStoredOptions()
				}

				if let optionsView = self.optionsView, let superview = self.volumeView.superview {
					// Apply rounded edges.
					optionsView.layer!.cornerRadius = 5.0

					// Add to the superview.
					superview.addSubview(optionsView)

					// Apply constraints to appear centred and above the volume view.
					let constraints = [
						optionsView.centerXAnchor.constraint(equalTo: volumeView.centerXAnchor),
						optionsView.bottomAnchor.constraint(equalTo: volumeView.topAnchor, constant: -8.0),
					]
					superview.addConstraints(constraints)
				}
			}

			// Set up a fader for the volume and options.
			var fadingViews: [NSView] = []
			if let optionsView = self.optionsView {
				fadingViews.append(optionsView)
			}
			if let volumeView = self.volumeView {
				fadingViews.append(volumeView)
			}
			optionsFader = ViewFader(views: fadingViews)

			// Create and populate an activity display if required.
			setupActivityDisplay()

			machine.delegate = self

			// If this machine has a mouse, enable mouse capture; also indicate whether usurption
			// of the command key is desired.
			scanTargetView.shouldCaptureMouse = machine.hasMouse
			scanTargetView.shouldUsurpCommand = machine.shouldUsurpCommand

			setupAudioQueueClockRate()

			// Bring OpenGL view-holding window on top of the options panel and show the content.
			scanTargetView.isHidden = false
			scanTargetView.window!.makeKeyAndOrderFront(self)
			scanTargetView.window!.makeFirstResponder(scanTargetView)

			// Insert command-line media before start so autoboot sees it.
			applyPendingFourADMediaIfNeeded()
			scheduleFourADInteractiveBootIfNeeded()
			// Start forwarding best-effort updates.
			machine.start()
			scheduleFourADArtifactExportIfNeeded()
			scheduleFourADFailFastIfNeeded()
			optionsFader?.showTransiently(for: 1.0)
		}
	}

	private static func fourADArgumentValue(_ name: String, arguments: [String]) -> String? {
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

	private static func parseFourADScriptSteps(_ argument: String?) -> [FourADScriptStep] {
		guard let argument = argument, !argument.isEmpty else {
			return []
		}

		let expanded = NSString(string: argument).expandingTildeInPath
		let data: Data
		if FileManager.default.fileExists(atPath: expanded), let fileData = try? Data(contentsOf: URL(fileURLWithPath: expanded)) {
			data = fileData
		} else {
			data = Data(argument.utf8)
		}

		guard let raw = try? JSONSerialization.jsonObject(with: data) else {
			return []
		}
		let rawSteps: [[String: Any]]
		if let steps = raw as? [[String: Any]] {
			rawSteps = steps
		} else if let object = raw as? [String: Any], let steps = object["steps"] as? [[String: Any]] {
			rawSteps = steps
		} else {
			return []
		}

		return rawSteps.enumerated().map { index, raw in
			let action = (raw["action"] as? String) ?? "delay"
			let name = (raw["name"] as? String) ?? "\(index)-\(action)"
			let delayMs = raw["delayMs"] as? Double
			let delaySeconds = raw["delaySeconds"] as? Double
			let timeoutSeconds = raw["timeoutSeconds"] as? Double
			return FourADScriptStep(
				action: action,
				name: name,
				key: raw["key"] as? String,
				text: raw["text"] as? String,
				delay: TimeInterval(delaySeconds ?? ((delayMs ?? 0.0) / 1000.0)),
				timeout: TimeInterval(timeoutSeconds ?? 20.0),
				snapshot: raw["snapshot"] as? String,
				expect: (raw["expect"] as? [String: Any]) ?? [:])
		}
	}

	private static func parseFourADArtifactOptions(arguments: [String]) -> FourADArtifactOptions? {
		guard let directoryArgument = fourADArgumentValue("--fourad-artifact-dir", arguments: arguments) else {
			return nil
		}

		let directoryPath = NSString(string: directoryArgument).expandingTildeInPath
		let bootDelayArgument = fourADArgumentValue("--fourad-boot-delay", arguments: arguments)
		let bootDelay = TimeInterval(bootDelayArgument ?? "") ?? 10.0
		let bootCommand = fourADArgumentValue("--fourad-boot-command", arguments: arguments)
		let keysArgument = fourADArgumentValue("--fourad-keys", arguments: arguments) ?? ""
		let keys = keysArgument.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
		let scriptSteps = parseFourADScriptSteps(fourADArgumentValue("--fourad-script", arguments: arguments))

		return FourADArtifactOptions(
			directory: URL(fileURLWithPath: directoryPath),
			bootDelay: bootDelay,
			bootCommand: bootCommand,
			keys: keys,
			scriptSteps: scriptSteps,
			quitAfterArtifact: arguments.contains("--fourad-quit-after-artifact"),
			failFast: arguments.contains("--fourad-fail-fast"),
			diskSnapshot: arguments.contains("--fourad-disk-snapshot"))
	}

	private func scheduleFourADArtifactExportIfNeeded() {
		guard !fourADArtifactScheduled, let options = fourADArtifactOptions else {
			return
		}
		fourADArtifactScheduled = true
		writeFourADArtifactState("scheduled export after \(options.bootDelay)s", to: options.directory)

		if let bootCommand = options.bootCommand, options.scriptSteps.isEmpty {
			DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
				self?.writeFourADArtifactState("typing boot command", to: options.directory)
				self?.machine.paste(bootCommand)
			}
		}

		DispatchQueue.main.asyncAfter(deadline: .now() + options.bootDelay) { [weak self] in
			guard let self = self else { return }
			if options.scriptSteps.isEmpty {
				self.writeFourADArtifactState("starting export", to: options.directory)
				self.exportFourADArtifacts(options: options)
			} else {
				self.writeFourADArtifactState("starting scripted automation", to: options.directory)
				self.runFourADScript(options: options, index: 0)
			}
		}
	}

	private func exportFourADArtifacts(options: FourADArtifactOptions) {
		do {
			try FileManager.default.createDirectory(at: options.directory, withIntermediateDirectories: true, attributes: nil)
			if options.diskSnapshot {
				writeFourADDiskCatalog(to: options.directory)
			}
			try exportFourADSnapshot(
				to: options.directory,
				screenshotName: "screen.png",
				debugName: "debug.json",
				textName: "screen-text.txt")
			writeFourADArtifactState("wrote initial snapshot", to: options.directory)

			if options.keys.isEmpty {
				if options.quitAfterArtifact {
					NSApp.terminate(self)
				}
				return
			}

			sendFourADKeys(options.keys)
			let afterKeysDelay = max(10.0, Double(options.keys.count) * 0.8 + 1.5)
			DispatchQueue.main.asyncAfter(deadline: .now() + afterKeysDelay) { [weak self] in
				guard let self = self else { return }
				do {
					self.writeFourADArtifactState("starting after-keys export", to: options.directory)
					try self.exportFourADSnapshot(
						to: options.directory,
						screenshotName: "after-keys.png",
						debugName: "after-keys-debug.json",
						textName: "after-keys-screen-text.txt")
					self.writeFourADArtifactState("wrote after-keys snapshot", to: options.directory)
				} catch {
					self.writeFourADExportError(error, to: options.directory)
				}
				if options.quitAfterArtifact {
					NSApp.terminate(self)
				}
			}
		} catch {
			writeFourADExportError(error, to: options.directory)
			if options.quitAfterArtifact {
				NSApp.terminate(self)
			}
		}
	}

	private func sendFourADKeys(_ keys: [String]) {
		machine.inputMode = .keyboardLogical
		for (index, key) in keys.enumerated() {
			guard let keyInfo = fourADKeyInfo(for: key) else {
				continue
			}
			let baseDelay = 0.5 + Double(index) * 0.7
			DispatchQueue.main.asyncAfter(deadline: .now() + baseDelay) { [weak self] in
				self?.writeFourADArtifactState("key down \(key)", to: self?.fourADArtifactOptions?.directory ?? URL(fileURLWithPath: "/tmp"))
				self?.machine.setKey(keyInfo.keyCode, characters: keyInfo.characters, isPressed: true, isRepeat: false)
			}
			DispatchQueue.main.asyncAfter(deadline: .now() + baseDelay + 0.35) { [weak self] in
				self?.writeFourADArtifactState("key up \(key)", to: self?.fourADArtifactOptions?.directory ?? URL(fileURLWithPath: "/tmp"))
				self?.machine.setKey(keyInfo.keyCode, characters: keyInfo.characters, isPressed: false, isRepeat: false)
			}
		}
	}

	private func pressFourADKey(_ key: String, completion: @escaping () -> Void) {
		guard let keyInfo = fourADKeyInfo(for: key) else {
			writeFourADArtifactState("ignored unknown key \(key)", to: fourADArtifactOptions?.directory ?? URL(fileURLWithPath: "/tmp"))
			DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: completion)
			return
		}
		machine.inputMode = .keyboardLogical
		DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
			self?.writeFourADArtifactState("key down \(key)", to: self?.fourADArtifactOptions?.directory ?? URL(fileURLWithPath: "/tmp"))
			self?.machine.setKey(keyInfo.keyCode, characters: keyInfo.characters, isPressed: true, isRepeat: false)
		}
		DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
			self?.writeFourADArtifactState("key up \(key)", to: self?.fourADArtifactOptions?.directory ?? URL(fileURLWithPath: "/tmp"))
			self?.machine.setKey(keyInfo.keyCode, characters: keyInfo.characters, isPressed: false, isRepeat: false)
			DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: completion)
		}
	}

	private func typeFourADTextAsKeys(_ text: String, completion: @escaping () -> Void) -> Bool {
		var keys: [String] = []
		for character in text {
			if character == "\r" || character == "\n" {
				keys.append("return")
			} else if character == " " {
				keys.append("space")
			} else {
				keys.append(String(character))
			}
		}
		guard !keys.isEmpty, keys.allSatisfy({ fourADKeyInfo(for: $0) != nil }) else {
			return false
		}
		func press(index: Int) {
			if index >= keys.count {
				completion()
				return
			}
			pressFourADKey(keys[index]) {
				press(index: index + 1)
			}
		}
		press(index: 0)
		return true
	}

	private func pasteFourADTextSlowly(_ text: String, interval: TimeInterval = 0.12, completion: @escaping () -> Void) {
		let characters = Array(text)
		func paste(index: Int) {
			if index >= characters.count {
				completion()
				return
			}
			let character = characters[index]
			let chunk = (character == "\n") ? "\r" : String(character)
			machine.paste(chunk)
			DispatchQueue.main.asyncAfter(deadline: .now() + interval) {
				paste(index: index + 1)
			}
		}
		paste(index: 0)
	}

	private func runFourADScript(options: FourADArtifactOptions, index: Int) {
		if index >= options.scriptSteps.count {
			finishFourADScript(options: options)
			return
		}

		let step = options.scriptSteps[index]
		fourADAutomationStepIndex = index
		fourADAutomationStepName = step.name
		fourADAutomationLastResult = "running"
		writeFourADArtifactState("script step \(index): \(step.name) [\(step.action)]", to: options.directory)

		let continueScript = { [weak self] in
			self?.fourADAutomationLastResult = "ok"
			self?.runFourADScript(options: options, index: index + 1)
		}

		switch step.action.lowercased() {
			case "boot":
				let text = step.text ?? options.bootCommand ?? "*EXEC !BOOT\n"
				writeFourADArtifactState("boot command \(text.replacingOccurrences(of: "\n", with: "\\n"))", to: options.directory)
				let command = text.replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: "")
				machine.paste(command)
				DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
					self?.pressFourADKey("return") {
						DispatchQueue.main.asyncAfter(deadline: .now() + max(step.delay, 0.5), execute: continueScript)
					}
				}
			case "type":
				let text = step.text ?? ""
				machine.paste(text)
				DispatchQueue.main.asyncAfter(deadline: .now() + max(step.delay, 0.2), execute: continueScript)
			case "typekeys":
				let text = step.text ?? ""
				if !typeFourADTextAsKeys(text, completion: {
					DispatchQueue.main.asyncAfter(deadline: .now() + max(step.delay, 0.2), execute: continueScript)
				}) {
					writeFourADArtifactState("ignored unsupported typeKeys text \(text)", to: options.directory)
					DispatchQueue.main.asyncAfter(deadline: .now() + max(step.delay, 0.2), execute: continueScript)
				}
			case "key":
				pressFourADKey(step.key ?? "") {
					DispatchQueue.main.asyncAfter(deadline: .now() + max(step.delay, 0.0), execute: continueScript)
				}
			case "delay":
				DispatchQueue.main.asyncAfter(deadline: .now() + max(step.delay, 0.1), execute: continueScript)
			case "waitfor":
				waitForFourADCondition(step: step, options: options) { [weak self] ok in
					if ok {
						continueScript()
					} else {
						self?.fourADAutomationLastResult = "timeout"
						self?.writeFourADArtifactState("script wait timed out: \(step.name)", to: options.directory)
						try? self?.exportFourADSnapshot(
							to: options.directory,
							screenshotName: "wait-failed.png",
							debugName: "wait-failed-debug.json",
							textName: "wait-failed-screen-text.txt")
						if options.quitAfterArtifact {
							NSApp.terminate(self)
						}
					}
				}
			case "snapshot":
				let name = sanitizeFourADFileStem(step.snapshot ?? step.name)
				let files = fourADSnapshotFilenames(for: name)
				try? exportFourADSnapshot(
					to: options.directory,
					screenshotName: files.screenshot,
					debugName: files.debug,
					textName: files.text)
				DispatchQueue.main.asyncAfter(deadline: .now() + max(step.delay, 0.1), execute: continueScript)
			case "diskcatalog":
				writeFourADDiskCatalog(to: options.directory)
				DispatchQueue.main.asyncAfter(deadline: .now() + max(step.delay, 0.1), execute: continueScript)
			case "quit":
				finishFourADScript(options: options)
			default:
				writeFourADArtifactState("ignored unknown script action \(step.action)", to: options.directory)
				DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: continueScript)
		}
	}

	private func finishFourADScript(options: FourADArtifactOptions) {
		fourADAutomationStepIndex = options.scriptSteps.count
		fourADAutomationStepName = "complete"
		fourADAutomationLastResult = "ok"
		do {
			if options.diskSnapshot {
				writeFourADDiskCatalog(to: options.directory)
			}
			try exportFourADSnapshot(
				to: options.directory,
				screenshotName: "after-keys.png",
				debugName: "after-keys-debug.json",
				textName: "after-keys-screen-text.txt")
			writeFourADArtifactState("script complete; wrote final snapshot", to: options.directory)
		} catch {
			writeFourADExportError(error, to: options.directory)
		}
		if options.quitAfterArtifact {
			NSApp.terminate(self)
		}
	}

	private func waitForFourADCondition(step: FourADScriptStep, options: FourADArtifactOptions, completion: @escaping (Bool) -> Void) {
		let deadline = Date().addingTimeInterval(step.timeout)
		func poll() {
			if self.fourADConditionMatches(step.expect, artifactDirectory: options.directory) {
				self.writeFourADArtifactState("wait matched: \(step.name)", to: options.directory)
				completion(true)
				return
			}
			if Date() >= deadline {
				completion(false)
				return
			}
			DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: poll)
		}
		poll()
	}

	private func fourADConditionMatches(_ expect: [String: Any], artifactDirectory: URL) -> Bool {
		guard let snapshot = self.machine.electronDebugSnapshot() as? [String: Any] else {
			return false
		}
		let screenText = (snapshot["screenText"] as? String) ?? ""
		let basicError = (snapshot["basicError"] as? String) ?? ""
		if let noBasicError = expect["noBasicError"] as? Bool, noBasicError, !basicError.isEmpty {
			return false
		}
		if let expectedBasicError = expect["basicError"] {
			if let bool = expectedBasicError as? Bool {
				if bool != !basicError.isEmpty { return false }
			} else if let text = expectedBasicError as? String, !basicError.contains(text) {
				return false
			}
		}
		if let token = expect["screenContains"] as? String, !screenText.uppercased().contains(token.uppercased()) {
			return false
		}
		if let tokens = expect["screenContains"] as? [String] {
			for token in tokens where !screenText.uppercased().contains(token.uppercased()) {
				return false
			}
		}
		if let token = expect["screenContainsAny"] as? String, !screenText.uppercased().contains(token.uppercased()) {
			return false
		}
		if let tokens = expect["screenContainsAny"] as? [String], !tokens.contains(where: { screenText.uppercased().contains($0.uppercased()) }) {
			return false
		}
		if let value = numberValue(expect["himem"]), numberValue(snapshot["himem"]) != value {
			return false
		}
		if let minimum = numberValue(expect["freeBytesAtLeast"]), (numberValue(snapshot["freeBytes"]) ?? -1) < minimum {
			return false
		}
		if let minimum = numberValue(expect["hopAtLeast"]), (numberValue(snapshot["hopCount"]) ?? -1) < minimum {
			return false
		}
		if let value = numberValue(expect["gameState"]), numberValue((snapshot["resident"] as? [String: Any])?["N"]) != value {
			return false
		}
		if let value = numberValue(expect["nextMod"]), numberValue((snapshot["resident"] as? [String: Any])?["L"]) != value {
			return false
		}
		if !residentConditionMatches(expect["resident"] as? [String: Any], snapshot: snapshot, minimum: false) {
			return false
		}
		if !residentConditionMatches(expect["residentAtLeast"] as? [String: Any], snapshot: snapshot, minimum: true) {
			return false
		}
		if let token = expect["diskContains"] as? String {
			writeFourADDiskCatalog(to: artifactDirectory)
			let path = artifactDirectory.appendingPathComponent("disk-catalog.txt")
			let catalog = (try? String(contentsOf: path, encoding: .utf8)) ?? ""
			if !catalog.contains(token) {
				return false
			}
		}
		return true
	}

	private func residentConditionMatches(_ condition: [String: Any]?, snapshot: [String: Any], minimum: Bool) -> Bool {
		guard let condition = condition else {
			return true
		}
		let resident = (snapshot["resident"] as? [String: Any]) ?? [:]
		for (key, expected) in condition {
			guard let actualNumber = numberValue(resident[key]), let expectedNumber = numberValue(expected) else {
				return false
			}
			if minimum {
				if actualNumber < expectedNumber { return false }
			} else if actualNumber != expectedNumber {
				return false
			}
		}
		return true
	}

	private func numberValue(_ value: Any?) -> Double? {
		if let number = value as? NSNumber {
			return number.doubleValue
		}
		if let int = value as? Int {
			return Double(int)
		}
		if let double = value as? Double {
			return double
		}
		if let string = value as? String {
			return Double(string)
		}
		return nil
	}

	private func sanitizeFourADFileStem(_ raw: String) -> String {
		let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
		let scalars = raw.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
		let out = String(scalars)
		return out.isEmpty ? "snapshot" : out
	}

	private func fourADSnapshotFilenames(for name: String) -> (screenshot: String, debug: String, text: String) {
		if name == "screen" {
			return ("screen.png", "debug.json", "screen-text.txt")
		}
		if name == "after-keys" {
			return ("after-keys.png", "after-keys-debug.json", "after-keys-screen-text.txt")
		}
		return ("\(name).png", "\(name)-debug.json", "\(name)-screen-text.txt")
	}

	private func fourADKeyInfo(for key: String) -> (keyCode: UInt16, characters: String)? {
		switch key.lowercased() {
			case "w": return (UInt16(VK_ANSI_W), "w")
			case "a": return (UInt16(VK_ANSI_A), "a")
			case "s": return (UInt16(VK_ANSI_S), "s")
			case "d": return (UInt16(VK_ANSI_D), "d")
			case "b": return (UInt16(VK_ANSI_B), "b")
			case "c": return (UInt16(VK_ANSI_C), "c")
			case "e": return (UInt16(VK_ANSI_E), "e")
			case "r": return (UInt16(VK_ANSI_R), "r")
			case "t": return (UInt16(VK_ANSI_T), "t")
			case "x": return (UInt16(VK_ANSI_X), "x")
			case "m": return (UInt16(VK_ANSI_M), "m")
			case "g": return (UInt16(VK_ANSI_G), "g")
			case "f": return (UInt16(VK_ANSI_F), "f")
			case "l": return (UInt16(VK_ANSI_L), "l")
			case "q": return (UInt16(VK_ANSI_Q), "q")
			case "n": return (UInt16(VK_ANSI_N), "n")
			case "o": return (UInt16(VK_ANSI_O), "o")
			case "enter", "return": return (UInt16(36), "\r")
			case "1": return (UInt16(VK_ANSI_1), "1")
			case "2": return (UInt16(VK_ANSI_2), "2")
			case "3": return (UInt16(VK_ANSI_3), "3")
			case "4": return (UInt16(VK_ANSI_4), "4")
			case "5": return (UInt16(VK_ANSI_5), "5")
			case "6": return (UInt16(VK_ANSI_6), "6")
			case "7": return (UInt16(VK_ANSI_7), "7")
			case "8": return (UInt16(VK_ANSI_8), "8")
			case "9": return (UInt16(VK_ANSI_9), "9")
			case "0": return (UInt16(VK_ANSI_0), "0")
			case "space": return (UInt16(49), " ")
			case "*": return (UInt16(VK_ANSI_8), "*")
			case "!": return (UInt16(VK_ANSI_1), "!")
			default: return nil
		}
	}

	private func exportFourADSnapshot(to directory: URL, screenshotName: String, debugName: String, textName: String) throws {
		let imageRepresentation = self.machine.imageRepresentation
		guard let pngData = imageRepresentation.representation(using: .png, properties: [:]) else {
			throw NSError(domain: "FourADArtifactExport", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not encode PNG screenshot"])
		}
		try pngData.write(to: directory.appendingPathComponent(screenshotName))

		let rawSnapshot = self.machine.electronDebugSnapshot() as? [String: Any]
		var snapshot = sanitizeFourADSnapshot(rawSnapshot ?? ["error": "Electron debug snapshot unavailable"])
		snapshot["fourADHarnessVersion"] = 2
		snapshot["fourADAutomation"] = [
			"stepIndex": fourADAutomationStepIndex,
			"stepName": fourADAutomationStepName,
			"lastResult": fourADAutomationLastResult,
		]
		let jsonData = try JSONSerialization.data(withJSONObject: snapshot, options: [.prettyPrinted])
		try jsonData.write(to: directory.appendingPathComponent(debugName))

		if let screenText = snapshot["screenText"] as? String {
			try (screenText + "\n").write(to: directory.appendingPathComponent(textName), atomically: true, encoding: .utf8)
		}
	}

	private func sanitizeFourADSnapshot(_ snapshot: [String: Any]) -> [String: Any] {
		var sanitized: [String: Any] = [:]
		for (key, value) in snapshot {
			if let data = value as? Data {
				sanitized[key + "Base64"] = data.base64EncodedString()
				sanitized[key + "Bytes"] = data.count
			} else if JSONSerialization.isValidJSONObject([key: value]) {
				sanitized[key] = value
			} else {
				sanitized[key] = String(describing: value)
			}
		}
		return sanitized
	}

	private func writeFourADExportError(_ error: Error, to directory: URL) {
		let message = String(describing: error) + "\n"
		try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: nil)
		try? message.write(to: directory.appendingPathComponent("capture-error.txt"), atomically: true, encoding: .utf8)
	}

	private func writeFourADArtifactState(_ message: String, to directory: URL) {
		try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: nil)
		let line = "\(Date()): \(message)\n"
		let logURL = directory.appendingPathComponent("artifact-state.txt")
		guard let data = line.data(using: .utf8) else { return }
		if FileManager.default.fileExists(atPath: logURL.path), let handle = try? FileHandle(forWritingTo: logURL) {
			handle.seekToEndOfFile()
			handle.write(data)
			handle.closeFile()
		} else {
			try? data.write(to: logURL)
		}
	}

	private func writeFourADDiskCatalog(to directory: URL) {
		let manifestPath = directory.appendingPathComponent("manifest.json")
		guard let manifestData = try? Data(contentsOf: manifestPath),
			let manifest = try? JSONSerialization.jsonObject(with: manifestData) as? [String: Any],
			let diskPath = manifest["disk"] as? String else {
			return
		}
		let beebtools = NSHomeDirectory() + "/.local/bin/beebtools"
		guard FileManager.default.fileExists(atPath: beebtools) else {
			return
		}
		let process = Process()
		process.executableURL = URL(fileURLWithPath: beebtools)
		process.arguments = ["cat", diskPath]
		let pipe = Pipe()
		process.standardOutput = pipe
		try? process.run()
		process.waitUntilExit()
		let data = pipe.fileHandleForReading.readDataToEndOfFile()
		try? data.write(to: directory.appendingPathComponent("disk-catalog.txt"))
	}

	func machineSpeakerDidChangeInputClock(_ machine: CSMachine) {
		// setupAudioQueueClockRate not only needs blocking access to the machine,
		// but may be triggered on an arbitrary thread by a running machine, and that
		// running machine may not be able to stop running until it has been called
		// (e.g. if it is currently trying to run_until an audio event). Break the
		// deadlock with an async dispatch.
		DispatchQueue.main.async { [weak self] in
			self?.setupAudioQueueClockRate()
		}
	}

	private func setupAudioQueueClockRate() {
		// Establish and provide the audio queue, taking advice as to an appropriate sampling rate.
		//
		// TODO: audit for thread safety.
		let maximumSamplingRate = CSAudioQueue.preferredSamplingRate()
		let selectedSamplingRate =
			Float64(self.machine.idealSamplingRate(from: NSRange(location: 0, length: NSInteger(maximumSamplingRate))))
		let isStereo = self.machine.isStereo
		if selectedSamplingRate > 0 {
			// [Re]create the audio queue only if necessary.
			if 	self.audioQueue == nil ||
				self.audioQueue.samplingRate != selectedSamplingRate ||
				self.audioQueue != self.machine.audioQueue
			{
				self.machine.audioQueue = nil
				self.audioQueue = CSAudioQueue(samplingRate: Float64(selectedSamplingRate), isStereo:isStereo)
				self.machine.audioQueue = self.audioQueue
				self.machine.setAudioSamplingRate(
					Float(selectedSamplingRate), bufferSize:audioQueue.preferredBufferSize, stereo:isStereo)
			}
		}
	}

	// MARK: - Pasteboard Forwarding.

	/// Forwards any text currently on the pasteboard into the active machine.
	func paste(_ sender: Any) {
		let pasteboard = NSPasteboard.general
		guard let string = pasteboard.string(forType: .string), let machine = self.machine else {
			return
		}
		machine.paste(string)
	}

	// MARK: - Runtime Media Insertion.

	/// Delegate message to receive drag and drop files.
	final func scanTargetView(_ view: CSScanTargetView, didReceiveFileAt URL: URL) {
		insertFile(URL)
	}

	/// Action for the insert menu command; displays an NSOpenPanel and then segues into the same process
	/// as if a file had been received via drag and drop.
	@IBAction final func insertMedia(_ sender: AnyObject!) {
		let openPanel = NSOpenPanel()
		openPanel.message = "Hint: you can also insert media by dragging and dropping it onto the machine's window."
		openPanel.beginSheetModal(for: self.windowControllers[0].window!) { (response) in
			if response == .OK {
				for url in openPanel.urls {
					self.insertFile(url)
				}
			}
		}
	}

	private func insertFile(_ URL: URL) {
		// Try to insert media.
		let mediaSet = CSMediaSet(fileAt: URL)
		checkPermisions(mediaSet)
		if !mediaSet.empty {
			mediaSet.apply(to: self.machine)
			return
		}

		// Failing that see whether a new machine is required.
		if let newMachine = CSStaticAnalyser(fileAt: URL) {
			machine?.stop()
			self.interactionMode = .notStarted
			self.scanTargetView.willChangeScanTargetOwner()
			configureAs(newMachine)
		}
	}

	func insertFourADMedia(_ URL: URL) {
		pendingFourADMediaURL = URL
		applyPendingFourADMediaIfNeeded()
		scheduleFourADInteractiveBootIfNeeded()
	}

	private func applyPendingFourADMediaIfNeeded() {
		guard let URL = pendingFourADMediaURL, self.machine != nil else {
			return
		}
		let mediaSet = CSMediaSet(fileAt: URL)
		checkPermisions(mediaSet)
		if !mediaSet.empty {
			mediaSet.apply(to: self.machine)
			pendingFourADMediaURL = nil
		}
	}

	private func scheduleFourADInteractiveBootIfNeeded() {
		guard fourADArtifactOptions == nil else {
			return
		}
		guard fourADAutoBoot || fourADInteractiveBootCommand != nil else {
			return
		}
		let bootCommand = fourADInteractiveBootCommand ?? "*EXEC !BOOT\n"
		DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
			self?.machine.paste(bootCommand)
		}
	}

	private func scheduleFourADFailFastIfNeeded() {
		let failFast = fourADArtifactOptions?.failFast ?? ProcessInfo.processInfo.arguments.contains("--fourad-fail-fast")
		guard failFast else {
			return
		}
		fourADFailFastTimer?.invalidate()
		fourADFailFastTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
			self?.checkFourADFailFast()
		}
	}

	private func checkFourADFailFast() {
		guard let snapshot = self.machine.electronDebugSnapshot() as? [String: Any] else {
			return
		}
		let basicError = (snapshot["basicError"] as? String) ?? ""
		let screenText = (snapshot["screenText"] as? String) ?? ""
		let needles = ["No such variable", "Bad program", "Bad MODE", "Syntax error", "Mistake", "Type mismatch"]
		let matched = !basicError.isEmpty || needles.contains(where: { screenText.contains($0) })
		guard matched else {
			return
		}
		fourADFailFastTimer?.invalidate()
		fourADFailFastTimer = nil
		if let options = fourADArtifactOptions {
			do {
				try exportFourADSnapshot(
					to: options.directory,
					screenshotName: "fail-fast.png",
					debugName: "fail-fast-debug.json",
					textName: "fail-fast-screen-text.txt")
				writeFourADArtifactState("fail-fast BASIC error export", to: options.directory)
			} catch {
				writeFourADExportError(error, to: options.directory)
			}
			if options.quitAfterArtifact {
				NSApp.terminate(self)
			}
		}
	}

	private func checkPermisions(_ mediaSet: CSMediaSet) {
		mediaSet.addPermissionHandler()
	}

	override func revertToSaved(_ sender: Any?) {
		// Do nothing, as states aren't implemented yet.
	}

	// MARK: - Input Management.

	/// Upon a resign key, immediately releases all ongoing input mechanisms — any currently pressed keys,
	/// and joystick and mouse inputs.
	func windowDidResignKey(_ notification: Notification) {
		if let machine = self.machine {
			machine.clearAllKeys()
			machine.joystickManager = nil
		}
		self.scanTargetView.releaseMouse()
	}

	/// Upon becoming key, attaches joystick input to the machine.
	func windowDidBecomeKey(_ notification: Notification) {
		guard let machine = self.machine else {
			return
		}
		machine.joystickManager = (DocumentController.shared as! DocumentController).joystickManager
	}

	/// Forwards key down events directly to the machine.
	func keyDown(_ event: NSEvent) {
		if event.modifierFlags.contains([.command, .shift]) && event.charactersIgnoringModifiers?.lowercased() == "d" {
			showElectronDebugPanel()
			return
		}
		guard let machine = self.machine else {
			return
		}
		machine.setKey(event.keyCode, characters: event.characters, isPressed: true, isRepeat: event.isARepeat)
	}

	private var electronDebugPanel: CSElectronDebugPanel?

	func showElectronDebugPanel() {
		guard let machine = self.machine else { return }
		guard CSElectronDebugPanel.isAvailable(for: machine) else { return }
		if electronDebugPanel == nil {
			electronDebugPanel = CSElectronDebugPanel(machine: machine)
		}
		electronDebugPanel?.openDebugWindow()
	}

	/// Forwards key up events directly to the machine.
	func keyUp(_ event: NSEvent) {
		guard let machine = self.machine else {
			return
		}
		machine.setKey(event.keyCode, characters: event.characters, isPressed: false, isRepeat: false)
	}

	/// Synthesies appropriate key up and key down events upon any change in modifiers.
	func flagsChanged(_ newModifiers: NSEvent) {
		guard let machine = self.machine else {
			return
		}

		if newModifiers.modifierFlags.contains(.shift) != shiftIsDown {
			shiftIsDown = newModifiers.modifierFlags.contains(.shift)
			machine.setKey(VK_Shift, characters: nil, isPressed: shiftIsDown, isRepeat: false)
			machine.setKey(VK_RightShift, characters: nil, isPressed: shiftIsDown, isRepeat: false)
		}
		if newModifiers.modifierFlags.contains(.control) != controlIsDown {
			controlIsDown = newModifiers.modifierFlags.contains(.control)
			machine.setKey(VK_Control, characters: nil, isPressed: controlIsDown, isRepeat: false)
			machine.setKey(VK_RightControl, characters: nil, isPressed: controlIsDown, isRepeat: false)
		}
		if newModifiers.modifierFlags.contains(.command) != commandIsDown {
			commandIsDown = newModifiers.modifierFlags.contains(.command)
			machine.setKey(VK_Command, characters: nil, isPressed: commandIsDown, isRepeat: false)
		}
		if newModifiers.modifierFlags.contains(.option) != optionIsDown {
			optionIsDown = newModifiers.modifierFlags.contains(.option)
			machine.setKey(VK_Option, characters: nil, isPressed: optionIsDown, isRepeat: false)
			machine.setKey(VK_RightOption, characters: nil, isPressed: optionIsDown, isRepeat: false)
		}
	}
	private var shiftIsDown = false
	private var controlIsDown = false
	private var commandIsDown = false
	private var optionIsDown = false

	/// Forwards mouse movement events to the mouse.
	func mouseMoved(_ event: NSEvent) {
		guard let machine = self.machine else {
			return
		}
		machine.addMouseMotionX(event.deltaX, y: event.deltaY)
	}

	/// Forwards mouse button down events to the mouse.
	func mouseUp(_ event: NSEvent) {
		guard let machine = self.machine else {
			return
		}
		machine.setMouseButton(Int32(event.buttonNumber), isPressed: false)
	}

	/// Forwards mouse button up events to the mouse.
	func mouseDown(_ event: NSEvent) {
		guard let machine = self.machine else {
			return
		}
		machine.setMouseButton(Int32(event.buttonNumber), isPressed: true)
	}

	// MARK: - MachinePicker Outlets and Actions

	@IBOutlet var machinePicker: MachinePicker?
	@IBOutlet var machinePickerPanel: NSWindow?
	@IBAction func createMachine(_ sender: NSButton?) {
		let selectedMachine = machinePicker!.selectedMachine()
		self.windowControllers[0].window?.endSheet(self.machinePickerPanel!)
		self.machinePicker = nil
		self.configureAs(selectedMachine)
	}

	@IBAction func tableViewDoubleClick(_ sender: NSTableView?) {
		createMachine(nil)
	}

	@IBAction func cancelCreateMachine(_ sender: NSButton?) {
		close()
	}

	// MARK: - ROMRequester Outlets and Actions

	@IBOutlet var romRequesterPanel: NSWindow?
	@IBOutlet var romRequesterText: NSTextField?
	@IBOutlet var romReceiverErrorField: NSTextField?
	@IBOutlet var romReceiverView: CSROMReceiverView?
	private var romRequestBaseText = ""

	private func setRomRequesterIsVisible(_ isVisible : Bool) {
		if !isVisible && self.romRequesterPanel == nil {
			return
		}

		if self.romRequesterPanel!.isVisible == isVisible {
			return
		}

		if isVisible {
			self.windowControllers[0].window?.beginSheet(self.romRequesterPanel!, completionHandler: nil)
		} else {
			self.windowControllers[0].window?.endSheet(self.romRequesterPanel!)
		}
	}

	func requestRoms() {
		// Don't act yet if there's no window controller yet.
		if self.windowControllers.count == 0 {
			return
		}

		// Load the ROM requester dialogue if it's not already loaded.
		if self.romRequesterPanel == nil {
			Bundle.main.loadNibNamed("ROMRequester", owner: self, topLevelObjects: nil)
			self.romReceiverView!.delegate = self
			self.romRequestBaseText = romRequesterText!.stringValue
			romReceiverErrorField?.alphaValue = 0.0
		}

		// Populate the current absentee list.
		populateMissingRomList()

		// Show the thing.
		setRomRequesterIsVisible(true)
	}

	@IBAction func cancelRequestROMs(_ sender: NSButton?) {
		close()
	}

	func populateMissingRomList() {
		romRequesterText!.stringValue = self.romRequestBaseText + self.missingROMs
	}

	func romReceiverView(_ view: CSROMReceiverView, didReceiveFileAt URL: URL) {
		// Test whether the file identified matches any of the currently missing ROMs.
		// If so then remove that ROM from the missing list and update the request screen.
		// If no ROMs are still missing, start the machine.
		if CSMachine.attemptInstallROM(URL) {
			configureAs(self.machineDescription!)
		} else {
			showRomReceiverError(error: "Didn't recognise contents of \(URL.lastPathComponent)")
		}
	}

	// Yucky ugliness follows; my experience as an iOS developer intersects poorly with
	// NSAnimationContext hence the various stateful diplications below. isShowingError
	// should be essentially a duplicate of the current alphaValue, and animationCount
	// is to resolve my inability to figure out how to cancel scheduled animations.
	private var errorText = ""
	private var isShowingError = false
	private var animationCount = 0
	private func showRomReceiverError(error: String) {
		// Set or append the new error.
		if self.errorText.count > 0 {
			self.errorText = self.errorText + "\n" + error
		} else {
			self.errorText = error
		}

		// Apply the new complete text.
		romReceiverErrorField!.stringValue = self.errorText

		if !isShowingError {
			// Schedule the box's appearance.
			NSAnimationContext.beginGrouping()
			NSAnimationContext.current.duration = 0.1
			romReceiverErrorField?.animator().alphaValue = 1.0
			NSAnimationContext.endGrouping()
			isShowingError = true
		}

		// Schedule the box to disappear.
		self.animationCount = self.animationCount + 1
		let capturedAnimationCount = animationCount
		DispatchQueue.main.asyncAfter(deadline: DispatchTime.now() + .seconds(2)) { [weak self] in
			guard let self = self else {
				return
			}
			if self.animationCount == capturedAnimationCount {
				NSAnimationContext.beginGrouping()
				NSAnimationContext.current.duration = 1.0
				self.romReceiverErrorField?.animator().alphaValue = 0.0
				NSAnimationContext.endGrouping()
				self.isShowingError = false
				self.errorText = ""
			}
		}
	}

	// MARK: - Joystick-via-the-keyboard selection.

	@IBAction func useKeyboardAsPhysicalKeyboard(_ sender: NSMenuItem?) {
		machine.inputMode = .keyboardPhysical
	}

	@IBAction func useKeyboardAsLogicalKeyboard(_ sender: NSMenuItem?) {
		machine.inputMode = .keyboardLogical
	}

	@IBAction func useKeyboardAsJoystick(_ sender: NSMenuItem?) {
		machine.inputMode = .joystick
	}

	@IBAction func softReset(_ sender: NSMenuItem?) {
		machine.softReset()
	}

	@IBAction func hardReset(_ sender: NSMenuItem?) {
		machine.hardReset()
	}

	/// Determines which of the menu items to enable and disable based on the ability of the
	/// current machine to handle keyboard and joystick input, accept new media and whether
	/// it has an associted activity window.
	override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
		if let menuItem = item as? NSMenuItem {
			switch item.action {
				case #selector(self.useKeyboardAsPhysicalKeyboard):
					if machine == nil || !machine.hasExclusiveKeyboard {
						menuItem.state = .off
						return false
					}

					menuItem.state = machine.inputMode == .keyboardPhysical ? .on : .off
					return true

				case #selector(self.useKeyboardAsLogicalKeyboard):
					if machine == nil || !machine.hasExclusiveKeyboard {
						menuItem.state = .off
						return false
					}

					menuItem.state = machine.inputMode == .keyboardLogical ? .on : .off
					return true

				case #selector(self.useKeyboardAsJoystick):
					if machine == nil || !machine.hasJoystick {
						menuItem.state = .off
						return false
					}

					menuItem.state = machine.inputMode == .joystick ? .on : .off
					return true

				case #selector(self.insertMedia(_:)):
					return self.machine != nil && self.machine.canInsertMedia

				case #selector(self.softReset(_:)):
					return self.machine != nil && self.machine.canSoftReset

				case #selector(self.hardReset(_:)):
					return self.machine != nil && self.machine.canHardReset

				default: break
			}
		}
		return super.validateUserInterfaceItem(item)
	}

	// MARK: - Screenshots.

	/// Saves a screenshot of the machine's current display.
	@IBAction func saveScreenshot(_ sender: AnyObject!) {
		// Grab a date formatter and form a file name.
		let dateFormatter = DateFormatter()
		dateFormatter.dateStyle = .short
		dateFormatter.timeStyle = .long

		let filename =
			("Clock Signal Screen Shot " + dateFormatter.string(from: Date()) + ".png")
				.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: ".")
		let pictursURL = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)[0]
		let url = pictursURL.appendingPathComponent(filename)

		// Obtain the machine's current display.
		let imageRepresentation = self.machine.imageRepresentation

		// Encode as a PNG and save.
		let pngData = imageRepresentation.representation(using: .png, properties: [:])
		try! pngData?.write(to: url)
	}

	// MARK: - Window Title Updates.

	private var unadornedWindowTitle = ""
	private var mouseIsCaptured = false
	private var windowTitleSuffix = ""

	private func updateWindowTitle() {
		var title = self.unadornedWindowTitle
		if windowTitleSuffix != "" {
			title += windowTitleSuffix
		}
		if mouseIsCaptured {
			title += " (press ⌘+control to release mouse)"
		}
		self.windowControllers[0].window?.title = title
	}

	internal func scanTargetViewDidCaptureMouse(_ view: CSScanTargetView) {
		mouseIsCaptured = true
		updateWindowTitle()
	}

	internal func scanTargetViewDidReleaseMouse(_ view: CSScanTargetView) {
		mouseIsCaptured = false
		updateWindowTitle()
	}

	// MARK: - Activity Display.

	private class LED {
		let levelIndicator: NSLevelIndicator
		init(levelIndicator: NSLevelIndicator, isPersistent: Bool) {
			self.levelIndicator = levelIndicator
			self.isPersistent = isPersistent
		}
		var isLit = false
		var isBlinking = false
		var isPersistent = false
	}
	private var leds: [String: LED] = [:]
	private var activityFader: ViewFader! = nil

	func setupActivityDisplay() {
		var leds = machine.leds
		if !leds.isEmpty {
			Bundle.main.loadNibNamed("Activity", owner: self, topLevelObjects: nil)

			// Inspect the activity panel for indicators.
			var activityIndicators: [NSLevelIndicator] = []
			var textFields: [NSTextField] = []
			if let activityView = self.activityView {
				for view in activityView.subviews {
					if let levelIndicator = view as? NSLevelIndicator {
						activityIndicators.append(levelIndicator)
					}

					if let textField = view as? NSTextField {
						textFields.append(textField)
					}
				}
			}

			// If there are fewer level indicators than LEDs, trim that list.
			if activityIndicators.count < leds.count {
				leds.removeSubrange(activityIndicators.count ..< leds.count)
			}

			// Remove unused views.
			for c in leds.count ..< activityIndicators.count {
				textFields[c].removeFromSuperview()
				activityIndicators[c].removeFromSuperview()
			}

			// Apply labels and create leds entries.
			for c in 0 ..< leds.count {
				textFields[c].stringValue = leds[c].name
				self.leds[leds[c].name] = LED(levelIndicator: activityIndicators[c], isPersistent: leds[c].isPersisent)
			}

			// Create a fader.
			activityFader = ViewFader(views: [self.activityView!])

			// Add view to window, and constrain.
			if let superview = activityIndicators[leds.count-1].superview {
				superview.addConstraint(
					activityIndicators[leds.count-1].bottomAnchor
						.constraint(equalTo: activityIndicators[leds.count-1].superview!.bottomAnchor, constant: -8.0)
				)
			}
			if let windowView = self.volumeView.superview {
				windowView.addSubview(self.activityView)

				let constraints = [
					self.activityView.rightAnchor.constraint(equalTo: windowView.rightAnchor),
					self.activityView.topAnchor.constraint(equalTo: windowView.topAnchor),
				]
				windowView.addConstraints(constraints)

				activityView.layer!.cornerRadius = 5.0
				activityView.layer!.maskedCorners = [.layerMinXMinYCorner]
			}

			// Show or hide activity view as per current state.
			updateActivityViewVisibility(true)
		}
	}

	func machine(_ machine: CSMachine, ledShouldBlink ledName: String) {
		// If there is such an LED, switch it off for 0.03 of a second; if it's meant
		// to be off at the end of that, leave it off. Don't allow the blinks to
		// pile up — allow there to be only one in flight at a time.
		guard let led = leds[ledName] else {
			return
		}

		DispatchQueue.main.async {
			if !led.isBlinking && led.isLit {
				led.levelIndicator.floatValue = 0.0
				led.isBlinking = true

				DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) {
					led.levelIndicator.floatValue = led.isLit ? 1.0 : 0.0
					led.isBlinking = false
				}
			}
		}
	}

	func machine(_ machine: CSMachine, led ledName: String, didChangeToLit isLit: Bool) {
		// If there is such an LED, switch it appropriately.
		guard let led = leds[ledName] else {
			return
		}

		DispatchQueue.main.async { [weak self] in
			// Do nothing for no change of state.
			if led.isLit == isLit {
				return
			}

			led.levelIndicator.floatValue = isLit ? 1.0 : 0.0
			led.isLit = isLit

			// Possibly show or hide the activity subview.
			self?.updateActivityViewVisibility(false, changed: ledName)
		}
	}

	private func updateActivityViewVisibility(_ isAppLaunch : Bool = false, changed: String? = nil) {
		if let window = self.windowControllers.first?.window, let activityFader = self.activityFader {
			// Rules applied below:
			//
			// Fullscreen:
			//	(i) always show activity view if any persistent LEDs are present;
			//	(ii) otherwise, show activity view only while at least one LED is lit.
			//
			// Windowed:
			//	(i) show while any non-persistent LED is lit;
			//	(ii) show transiently to indicate a change of state in any persistent LED.
			//
			let hasLitLEDs = !self.leds.filter {
				$0.value.isLit && (!$0.value.isPersistent || window.styleMask.contains(.fullScreen)) ||
				($0.value.isPersistent && window.styleMask.contains(.fullScreen))
			}.isEmpty
			let shouldShowTransient =
				!window.styleMask.contains(.fullScreen) && changed != nil && self.leds[changed!]!.isPersistent

			if hasLitLEDs {
				activityFader.animateIn()
			} else if shouldShowTransient {
				activityFader.showTransiently(for: 1.0)
			} else {
				activityFader.animateOut(delay: 0.2)
			}
		}
	}

	// MARK: - In-window panels (i.e. options, volume).

	private var optionsFader: ViewFader? = nil

	internal func scanTargetView(_ view: CSScanTargetView, shouldTrackMousovers subview: NSView) -> Bool {
		return subview == self.volumeView || subview == self.optionsView
	}

	internal func scanTargetViewDidMouseoverSubviews(_ view: CSScanTargetView) {
		// The OS mouse cursor became visible, so show the options.
		optionsFader?.animateIn()
	}

	internal func scanTargetViewWouldHideOSMouseCursor(_ view: CSScanTargetView) {
		// The OS mouse cursor will be hidden, so hide the options if visible.
		optionsFader?.animateOut(delay: 0.0)
	}

	// MARK: - Helpers for fading things in and out.

	/// Maintains a list of views and offers in-and-out animations on those,
	/// testing current state as necessary and otherwise coordinating with
	/// CoreAnimation.
	private class ViewFader: NSObject, CAAnimationDelegate {
		private var views: [NSView]

		init(views: [NSView]) {
			self.views = views
			for view in views {
				view.isHidden = true
			}
		}

		func animationDidStop(_ animation: CAAnimation, finished: Bool) {
			if finished {
				for view in views {
					view.isHidden = true
				}
			}
		}

		func animateIn() {
			for view in views {
				view.layer?.removeAllAnimations()
				view.isHidden = false
			}
		}

		func animateOut(delay : TimeInterval) {
			// Do nothing if already animating out or invisible.
			if views[0].isHidden || views[0].layer?.animation(forKey: "opacity") != nil {
				return
			}

			for view in views {
				let fadeAnimation = CABasicAnimation(keyPath: "opacity")
				fadeAnimation.beginTime = CACurrentMediaTime() + delay
				fadeAnimation.fromValue = 1.0
				fadeAnimation.toValue = 0.0
				fadeAnimation.duration = 0.2
				fadeAnimation.delegate = self

				fadeAnimation.fillMode = .forwards
				fadeAnimation.isRemovedOnCompletion = false

				view.layer?.removeAllAnimations()
				view.layer!.add(fadeAnimation, forKey: "opacity")
			}
		}

		func showTransiently(for period: TimeInterval) {
			animateIn()
			animateOut(delay: period)
		}
	}

	// MARK: - Volume Control.

	@IBAction func setVolume(_ sender: NSSlider!) {
		if let machine = self.machine {
			let linearValue = log2(sender.floatValue)
			machine.setVolume(linearValue)
			setUserDefaultsVolume(linearValue)
		}
	}

	// The user's selected volume is stored as 1 - volume in the user defaults in order
	// to take advantage of the default value being 0.
	private func userDefaultsVolume() -> Float {
		return 1.0 - UserDefaults.standard.float(forKey: "defaultVolume")
	}

	private func setUserDefaultsVolume(_ volume: Float) {
		UserDefaults.standard.set(1.0 - volume, forKey: "defaultVolume")
	}
}
