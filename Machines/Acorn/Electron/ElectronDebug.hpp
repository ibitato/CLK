//
//  ElectronDebug.hpp
//  4 Against Darkness — Acorn Electron debug hooks for CLK
//

#pragma once

#include "Processors/6502/6502.hpp"

#include <algorithm>
#include <array>
#include <cstdint>
#include <cstdio>
#include <set>
#include <string>
#include <vector>

namespace Electron::Debug {

struct Workspace {
	uint16_t page = 0;
	uint16_t top = 0;
	uint16_t himem = 0;
	int free_bytes = 0;
};

struct Snapshot {
	uint16_t pc = 0;
	uint8_t a = 0;
	uint8_t x = 0;
	uint8_t y = 0;
	uint8_t sp = 0;
	uint8_t p = 0;
	Workspace workspace;
	bool paused = false;
	bool enabled = false;
	bool trap_brk = true;
	bool trap_breakpoints = true;
	std::string pause_reason;
};

inline uint16_t read16(const uint8_t *ram, const uint16_t address) {
	return uint16_t(ram[address]) | (uint16_t(ram[address + 1]) << 8);
}

inline Workspace read_workspace(const uint8_t *ram) {
	Workspace ws;
	ws.page = read16(ram, 0x218);
	ws.top = read16(ram, 0x216);
	ws.himem = read16(ram, 0x214);
	if(ws.top < ws.himem) {
		ws.free_bytes = int(ws.himem) - int(ws.top);
	}
	return ws;
}

inline const char *opcode_name(const uint8_t opcode) {
	static const char *names[256] = {
		"BRK","ORAidx","???","???","???","ORAzp","ASLzp","???","PHP","ORAimm","ASLacc","???","???","ORAabs","ASLabs","???",
		"BPL","ORAidy","???","???","???","ORAzpx","ASLzpx","???","CLC","ORAaby","???","???","???","ORAabx","ASLabx","???",
		"JSR","ANDidx","???","???","BITzp","ANDzp","ROLzp","???","PLP","ANDimm","ROLacc","???","BITabs","ANDabs","ROLabs","???",
		"BMI","ANDidy","???","???","???","ANDzpx","ROLzpx","???","SEC","ANDaby","???","???","???","ANDabx","ROLabx","???",
		"RTI","EORidx","???","???","???","EORzp","LSRzp","???","PHA","EORimm","LSRacc","???","JMPabs","EORabs","LSRabs","???",
		"BVC","EORidy","???","???","???","EORzpx","LSRzpx","???","CLI","EORaby","???","???","???","EORabx","LSRabx","???",
		"RTS","ADCidx","???","???","???","ADCzp","RORzp","???","PLA","ADCimm","RORacc","???","JMPind","ADCabs","RORabs","???",
		"BVS","ADCidy","???","???","???","ADCzpx","RORzpx","???","SEI","ADCaby","???","???","???","ADCabx","RORabx","???",
		"???","STAidx","???","???","STYzp","STAzp","STXzp","???","DEY","???","TXA","???","STYabs","STAabs","STXabs","???",
		"BCC","STAidy","???","???","STYzpx","STAzpx","STXzpy","???","TYA","STAaby","TXS","???","???","STAabx","???","???",
		"LDYimm","LDAidx","LDXimm","???","LDYzp","LDAzp","LDXzp","???","TAY","LDAimm","TAX","???","LDYabs","LDAabs","LDXabs","???",
		"BCS","LDAidy","???","???","LDYzpx","LDAzpx","LDXzpy","???","CLV","LDAaby","TSX","???","LDYabx","LDAabx","LDXaby","???",
		"CPYimm","???","???","???","CPYzp","???","DECzp","???","INY","???","???","???","CPYabs","???","INCabs","???",
		"BNE","???","???","???","???","???","INCzpx","???","CLD","???","???","???","???","???","INCabx","???",
		"CPXimm","SBCidx","???","???","CPXzp","SBCzp","INCzp","???","INX","SBCimm","NOP","???","CPXabs","SBCabs","INCabs","???",
		"BEQ","SBCidy","???","???","???","SBCzpx","INCzpx","???","SED","SBCaby","???","???","???","SBCabx","INCabx","???"
	};
	return names[opcode];
}

inline int instruction_length(const uint8_t opcode) {
	static const int lengths[256] = {
		2,6,0,0,0,3,3,0,1,2,2,0,0,4,4,0,
		2,5,0,0,0,4,4,0,1,4,0,0,0,4,4,0,
		3,6,0,0,3,3,3,0,1,2,2,0,4,4,4,0,
		2,5,0,0,0,4,4,0,1,4,0,0,0,4,4,0,
		1,6,0,0,0,3,3,0,1,2,2,0,3,4,4,0,
		2,5,0,0,0,4,4,0,1,4,0,0,0,4,4,0,
		1,6,0,0,0,3,3,0,1,2,2,0,3,4,4,0,
		2,5,0,0,0,4,4,0,1,4,0,0,0,4,4,0,
		0,6,0,0,3,3,3,0,1,0,1,0,4,4,4,0,
		2,5,0,0,4,4,4,0,1,4,1,0,0,4,0,0,
		2,6,2,0,3,3,3,0,1,2,1,0,4,4,4,0,
		2,5,0,0,4,4,4,0,1,4,1,0,4,4,4,0,
		2,0,0,0,3,0,3,0,1,0,0,0,4,0,4,0,
		2,0,0,0,0,0,4,0,1,0,0,0,0,0,4,0,
		2,6,0,0,3,3,3,0,1,2,1,0,4,4,4,0,
		2,5,0,0,0,4,4,0,1,4,0,0,0,4,4,0
	};
	return lengths[opcode];
}

inline std::string disassemble_line(const uint8_t *ram, const uint16_t address) {
	const uint8_t opcode = ram[address & 0x7fff];
	const int length = std::max(1, instruction_length(opcode));
	char bytes[32] = "";
	int offset = 0;
	for(int i = 0; i < length && i < 3; i++) {
		offset += std::snprintf(bytes + offset, sizeof(bytes) - offset, "%02X ", ram[(address + i) & 0x7fff]);
	}
	char line[128];
	std::snprintf(line, sizeof(line), "%04X: %-8s %s", address, bytes, opcode_name(opcode));
	return line;
}

class Controller {
public:
	bool enabled = false;
	bool paused = false;
	bool trap_brk = true;
	bool trap_breakpoints = true;
	bool step_pending = false;
	std::string pause_reason;

	void set_enabled(const bool on) {
		enabled = on;
		if(!enabled) {
			paused = false;
			step_pending = false;
		}
	}

	void pause_with_reason(const std::string &reason) {
		if(!enabled) return;
		paused = true;
		pause_reason = reason;
	}

	void continue_execution() {
		paused = false;
		step_pending = false;
		pause_reason.clear();
	}

	void request_step() {
		if(!enabled) return;
		paused = false;
		step_pending = true;
		pause_reason = "Step";
	}

	void request_pause() {
		if(!enabled) return;
		paused = true;
		pause_reason = "User pause";
	}

	bool add_breakpoint(const uint16_t address) {
		return breakpoints_.insert(address).second;
	}

	bool remove_breakpoint(const uint16_t address) {
		return breakpoints_.erase(address) > 0;
	}

	std::vector<uint16_t> breakpoints() const {
		return {breakpoints_.begin(), breakpoints_.end()};
	}

	void clear_breakpoints() {
		breakpoints_.clear();
	}

	bool should_pause_on_opcode(const uint16_t address, const uint8_t opcode) {
		if(!enabled) return false;

		if(step_pending) {
			step_pending = false;
			pause_with_reason(std::string("Step at ") + std::to_string(address));
			return true;
		}

		if(trap_brk && opcode == 0x00) {
			pause_with_reason(std::string("BRK at ") + std::to_string(address));
			return true;
		}

		if(trap_breakpoints && breakpoints_.contains(address)) {
			pause_with_reason(std::string("Breakpoint at ") + std::to_string(address));
			return true;
		}

		return false;
	}

	Snapshot snapshot(
		const CPU::MOS6502::ProcessorBase &cpu,
		const uint8_t *ram
	) const {
		Snapshot snap;
		snap.enabled = enabled;
		snap.paused = paused;
		snap.trap_brk = trap_brk;
		snap.trap_breakpoints = trap_breakpoints;
		snap.pause_reason = pause_reason;
		snap.pc = uint16_t(cpu.value_of(CPU::MOS6502::Register::ProgramCounter));
		snap.a = uint8_t(cpu.value_of(CPU::MOS6502::Register::A));
		snap.x = uint8_t(cpu.value_of(CPU::MOS6502::Register::X));
		snap.y = uint8_t(cpu.value_of(CPU::MOS6502::Register::Y));
		snap.sp = uint8_t(cpu.value_of(CPU::MOS6502::Register::StackPointer));
		snap.p = uint8_t(cpu.value_of(CPU::MOS6502::Register::Flags));
		if(ram) snap.workspace = read_workspace(ram);
		return snap;
	}

	std::vector<uint8_t> read_ram(const uint8_t *ram, const uint16_t address, const std::size_t length) const {
		std::vector<uint8_t> out(length);
		for(std::size_t i = 0; i < length; i++) {
			const uint16_t addr = uint16_t(address + i);
			out[i] = (addr < 0x8000) ? ram[addr] : 0xff;
		}
		return out;
	}

	std::string disassemble(
		const uint8_t *ram,
		const uint16_t address,
		const int count
	) const {
		std::string out;
		uint16_t pc = address;
		for(int i = 0; i < count; i++) {
			out += disassemble_line(ram, pc);
			out += '\n';
			pc = uint16_t(pc + instruction_length(ram[pc & 0x7fff]));
		}
		return out;
	}

	std::string screen_text(const uint8_t *ram, const uint16_t himem, const int cols, const int rows) const {
		std::string out;
		for(int row = 0; row < rows; row++) {
			for(int col = 0; col < cols; col++) {
				const uint16_t addr = uint16_t(himem + row * 320 + col * 8);
				const char ch = (addr < 0x8000) ? char(ram[addr] & 0x7f) : ' ';
				out.push_back((ch >= 32 && ch < 127) ? ch : ' ');
			}
			out.push_back('\n');
		}
		return out;
	}

	// BBC BASIC resident integer variables A%..Z% (4 bytes each from &404).
	inline int32_t read_resident_int(const uint8_t *ram, const char letter) const {
		if(!ram || letter < 'A' || letter > 'Z') return 0;
		const uint16_t addr = uint16_t(0x404 + (letter - 'A') * 4);
		if(addr + 3 >= 0x8000) return 0;
		const uint32_t raw =
			uint32_t(ram[addr]) |
			(uint32_t(ram[addr + 1]) << 8) |
			(uint32_t(ram[addr + 2]) << 16) |
			(uint32_t(ram[addr + 3]) << 24);
		return int32_t(raw);
	}

	inline bool write_resident_int(uint8_t *ram, const char letter, const int32_t value) const {
		if(!ram || letter < 'A' || letter > 'Z') return false;
		const uint16_t addr = uint16_t(0x404 + (letter - 'A') * 4);
		if(addr + 3 >= 0x8000) return false;
		const uint32_t raw = uint32_t(value);
		ram[addr] = uint8_t(raw & 0xff);
		ram[addr + 1] = uint8_t((raw >> 8) & 0xff);
		ram[addr + 2] = uint8_t((raw >> 16) & 0xff);
		ram[addr + 3] = uint8_t((raw >> 24) & 0xff);
		return true;
	}

	inline std::string find_basic_error(const std::string &screen) const {
		static const char *const needles[] = {
			"No such variable",
			"Bad program",
			"Bad MODE",
			"Syntax error",
			"Mistake",
			"Type mismatch",
			"Division by zero",
			"Out of memory",
		};
		for(const char *needle : needles) {
			if(screen.find(needle) != std::string::npos) {
				const auto start = screen.find(needle);
				auto end = screen.find('\n', start);
				if(end == std::string::npos) end = screen.size();
				return screen.substr(start, end - start);
			}
		}
		return {};
	}

private:
	std::set<uint16_t> breakpoints_;
};

} // namespace Electron::Debug
