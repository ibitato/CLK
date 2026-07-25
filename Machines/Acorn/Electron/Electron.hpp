//
//  Electron.hpp
//  Clock Signal
//
//  Created by Thomas Harte on 03/01/2016.
//  Copyright 2016 Thomas Harte. All rights reserved.
//

#pragma once

#include "Analyser/Static/StaticAnalyser.hpp"
#include "Configurable/Configurable.hpp"
#include "Configurable/StandardOptions.hpp"
#include "Machines/ROMMachine.hpp"

#include <cstdint>
#include <memory>
#include <string>
#include <vector>

namespace Electron::Debug {
struct Snapshot;
class Controller;
}

namespace Electron {

struct DebugSnapshot {
	uint16_t pc = 0;
	uint8_t a = 0, x = 0, y = 0, sp = 0, p = 0;
	uint16_t page = 0, top = 0, himem = 0;
	int free_bytes = 0;
	bool paused = false;
	bool enabled = false;
	bool trap_brk = true;
	bool trap_breakpoints = true;
	std::string pause_reason;
	std::vector<uint16_t> breakpoints;
	std::string disassembly;
	std::string screen_text;
	std::vector<uint8_t> memory_dump;
	std::string basic_error;
	int32_t resident_H = 0, resident_I = 0, resident_J = 0, resident_K = 0;
	int32_t resident_L = 0, resident_M = 0, resident_N = 0, resident_O = 0;
	int32_t resident_P = 0, resident_Q = 0, resident_R = 0, resident_S = 0;
};

/*!
	@abstract Represents an Acorn Electron.

	@discussion An instance of Electron::Machine represents the current state of an
	Acorn Electron.
*/
struct Machine {
	virtual ~Machine() = default;

	virtual bool debug_available() const { return false; }
	virtual DebugSnapshot debug_snapshot() { return {}; }
	virtual void debug_set_enabled(bool enabled) { (void)enabled; }
	virtual void debug_continue() {}
	virtual void debug_step() {}
	virtual void debug_pause() {}
	virtual bool debug_add_breakpoint(uint16_t address) { (void)address; return false; }
	virtual bool debug_remove_breakpoint(uint16_t address) { (void)address; return false; }
	virtual void debug_clear_breakpoints() {}
	virtual void debug_set_trap_brk(bool enabled) { (void)enabled; }
	virtual std::vector<uint8_t> debug_read_memory(uint16_t address, std::size_t length) {
		(void)address; (void)length; return {};
	}
	virtual int32_t debug_read_resident(char letter) {
		(void)letter; return 0;
	}
	virtual bool debug_set_resident(char letter, int32_t value) {
		(void)letter; (void)value; return false;
	}

	/// Creates and returns an Electron.
	static std::unique_ptr<Machine> create(const Analyser::Static::Target &, const ROMMachine::ROMFetcher &);

	/// Defines the runtime options available for an Electron.
	class Options:
		public Reflection::StructImpl<Options>,
		public Configurable::Options::Display<Options>,
		public Configurable::Options::QuickLoad<Options>
	{
		friend Configurable::Options::Display<Options>;
		friend Configurable::Options::QuickLoad<Options>;
	public:
		Options(const Configurable::OptionsType type) :
			Configurable::Options::Display<Options>(
				type == Configurable::OptionsType::UserFriendly ?
					Configurable::Display::RGB : Configurable::Display::CompositeColour
			),
			Configurable::Options::QuickLoad<Options>(
				type == Configurable::OptionsType::UserFriendly) {}

	private:
		Options() : Options(Configurable::OptionsType::UserFriendly) {}

		friend Reflection::StructImpl<Options>;
		void declare_fields() {
			declare_display_option();
			declare_quickload_option();
			limit_enum(
				&output,
				Configurable::Display::RGB,
				Configurable::Display::CompositeColour,
				Configurable::Display::CompositeMonochrome,
				-1
			);
		}
	};
};

}
