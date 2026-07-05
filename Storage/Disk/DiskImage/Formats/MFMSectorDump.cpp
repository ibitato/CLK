//
//  MFMSectorDump.cpp
//  Clock Signal
//
//  Created by Thomas Harte on 30/09/2017.
//  Copyright 2017 Thomas Harte. All rights reserved.
//

#include "MFMSectorDump.hpp"

#include "Storage/Disk/DiskImage/Formats/Utility/ImplicitSectors.hpp"

#include <algorithm>

using namespace Storage::Disk;

MFMSectorDump::MFMSectorDump(const std::string &file_name) : file_(file_name) {}

void MFMSectorDump::set_geometry(
	const int sectors_per_track,
	const uint8_t sector_size,
	const uint8_t first_sector,
	const Encodings::MFM::Density density,
	const int ideal_sector_spacing
) {
	sectors_per_track_ = sectors_per_track;
	sector_size_ = sector_size;
	density_ = density;
	first_sector_ = first_sector;
	ideal_sector_spacing_ = ideal_sector_spacing;
}

std::unique_ptr<Track> MFMSectorDump::track_at_position(const Track::Address address) const {
	if(address.head >= head_count()) return nullptr;
	if(address.position.as_largest() >= maximum_head_position().as_largest()) return nullptr;

	const auto size = size_t((128 << sector_size_) * sectors_per_track_);
	std::vector<uint8_t> sectors;
	const long file_offset = get_file_offset_for_position(address);

	{
		std::lock_guard lock_guard(file_.file_access_mutex());
		file_.seek(file_offset, Whence::SET);
		sectors = file_.read(size);
	}

	return track_for_sectors(
		sectors.data(),
		sectors_per_track_,
		uint8_t(address.position.as_int()),
		uint8_t(address.head),
		first_sector_,
		sector_size_,
		density_,
		ideal_sector_spacing_
	);
}

void MFMSectorDump::set_tracks(const std::map<Track::Address, std::unique_ptr<Track>> &tracks) {
	const auto size = size_t((128 << sector_size_) * sectors_per_track_);

	// TODO: it would be more efficient from a file access and locking point of view to parse the sectors
	// in one loop, then write in another.

	for(const auto &track : tracks) {
		const long file_offset = get_file_offset_for_position(track.first);
		std::vector<uint8_t> parsed_track(size, 0);

		{
			std::lock_guard lock_guard(file_.file_access_mutex());
			file_.ensure_is_at_least_length(file_offset + long(size));
			file_.seek(file_offset, Whence::SET);
			const auto bytes_read = file_.read(parsed_track.data(), size);
			if(bytes_read < size) {
				std::fill(parsed_track.begin() + std::ptrdiff_t(bytes_read), parsed_track.end(), 0);
			}
		}

		decode_sectors(
			*track.second,
			parsed_track.data(),
			first_sector_,
			first_sector_ + uint8_t(sectors_per_track_-1),
			sector_size_,
			density_);

		std::lock_guard lock_guard(file_.file_access_mutex());
		file_.ensure_is_at_least_length(file_offset + long(size));
		file_.seek(file_offset, Whence::SET);
		file_.write(parsed_track);
	}
	file_.flush();
}

bool MFMSectorDump::write_sector(
	const Track::Address address,
	const uint8_t sector,
	const uint8_t size,
	const std::vector<uint8_t> &data
) {
	if(address.head >= head_count()) return false;
	if(address.position.as_largest() >= maximum_head_position().as_largest()) return false;
	if(size != sector_size_) return false;
	if(sector < first_sector_) return false;
	if(sector >= first_sector_ + uint8_t(sectors_per_track_)) return false;

	const auto byte_size = size_t(128 << sector_size_);
	if(data.size() < byte_size) return false;

	const long file_offset = get_file_offset_for_position(address) +
		long((sector - first_sector_) * byte_size);
	std::vector<uint8_t> sector_data(data.begin(), data.begin() + std::ptrdiff_t(byte_size));

	std::lock_guard lock_guard(file_.file_access_mutex());
	file_.ensure_is_at_least_length(file_offset + long(byte_size));
	file_.seek(file_offset, Whence::SET);
	file_.write(sector_data);
	file_.flush();
	return true;
}

bool MFMSectorDump::is_read_only() const {
	return file_.is_known_read_only();
}

bool MFMSectorDump::represents(const std::string &name) const {
	return name == file_.name();
}
