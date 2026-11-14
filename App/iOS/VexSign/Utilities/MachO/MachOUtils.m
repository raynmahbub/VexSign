//
//  MachOUtils.m
//  VexSign
//
//  Created by VexSign Team on 12.06.2025.
//

#import "MachOUtils.h"

#define SDK_VERSION_26_0_0 0x1A0000

/// https://github.com/LiveContainer/LiveContainer/commit/3a029b6bb36c11cc05784a8840d41c7e46af1540
/// this is licensed under Apache-2.0, bundled when compiled.
NSString *LCPatchMachOFixupARM64eSlice(const char *path) {
	int fd = open(path, O_RDWR, 0600);
	if(fd < 0) {
		return [NSString stringWithFormat:@"Failed to open %s: %s", path, strerror(errno)];
	}
	struct stat s = {0};
	fstat(fd, &s);
	void *map = mmap(NULL, s.st_size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
	if(map == MAP_FAILED) {
		close(fd);
		return [NSString stringWithFormat:@"Failed to map %s: %s", path, strerror(errno)];
	}
	
	uint32_t magic = *(uint32_t *)map;
	if(magic == FAT_CIGAM) {
		// Find arm64e slice without CPU_SUBTYPE_LIB64
		struct fat_header *header = (struct fat_header *)map;
		struct fat_arch *arch = (struct fat_arch *)(map + sizeof(struct fat_header));
		for(int i = 0; i < OSSwapInt32(header->nfat_arch); i++) {
			if(OSSwapInt32(arch->cputype) == CPU_TYPE_ARM64 && OSSwapInt32(arch->cpusubtype) == CPU_SUBTYPE_ARM64E) {
				struct mach_header_64 *header = (struct mach_header_64 *)(map + OSSwapInt32(arch->offset));
				header->cpusubtype |= CPU_SUBTYPE_LIB64;
				arch->cpusubtype = htonl(header->cpusubtype);
				break;
			}
			arch = (struct fat_arch *)((void *)arch + sizeof(struct fat_arch));
		}
	}
	
	msync(map, s.st_size, MS_SYNC);
	munmap(map, s.st_size);
	close(fd);
	return nil;
}

static NSString *PatchMachOAtOffset(void *mapped, size_t fileSize, off_t offset, uint32_t index) {
	uint8_t *base = (uint8_t *)mapped + offset;
	
	if ((size_t)(offset + sizeof(struct mach_header_64)) > fileSize) {
		return [NSString stringWithFormat:@"Slice %u: Invalid offset or truncated header", index];
	}
	
	struct mach_header_64 *header = (struct mach_header_64 *)base;
	if (header->magic != MH_MAGIC_64) {
		return [NSString stringWithFormat:@"Slice %u: Unsupported or non-64-bit Mach-O", index];
	}
	
	struct load_command *cmd = (struct load_command *)(base + sizeof(struct mach_header_64));
	
	for (uint32_t i = 0; i < header->ncmds; i++) {
		uint8_t *cmdEnd = (uint8_t *)cmd + sizeof(struct load_command);
		if ((size_t)(cmdEnd - (uint8_t *)mapped) > fileSize) {
			return [NSString stringWithFormat:@"Slice %u: Load command exceeds file size", index];
		}
		
		if (cmd->cmd == LC_BUILD_VERSION) {
			struct build_version_command *bvc = (struct build_version_command *)cmd;
			bvc->sdk = SDK_VERSION_26_0_0;
			return [NSString stringWithFormat:@"Slice %u: Patched LC_BUILD_VERSION to SDK 26.0", index];
		}
		
		cmd = (struct load_command *)((uint8_t *)cmd + cmd->cmdsize);
	}
	
	return [NSString stringWithFormat:@"Slice %u: LC_BUILD_VERSION not found", index];
}

NSString *LCPatchMachOForSDK26(const char *path) {
	int fd = open(path, O_RDWR, 0600);
	if(fd < 0) {
		return [NSString stringWithFormat:@"Failed to open %s: %s", path, strerror(errno)];
	}
	struct stat s = {0};
	fstat(fd, &s);
	void *map = mmap(NULL, s.st_size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
	if(map == MAP_FAILED) {
		close(fd);
		return [NSString stringWithFormat:@"Failed to map %s: %s", path, strerror(errno)];
	}
	
	NSMutableString *result = [NSMutableString string];
	uint32_t magic = *(uint32_t *)map;
	
	if (magic == FAT_MAGIC || magic == FAT_CIGAM) {
		struct fat_header *fat = (struct fat_header *)map;
		uint32_t nfat = OSSwapBigToHostInt32(fat->nfat_arch);
		struct fat_arch *archs = (struct fat_arch *)((uint8_t *)map + sizeof(struct fat_header));
		
		for (uint32_t i = 0; i < nfat; i++) {
			uint32_t offset = OSSwapBigToHostInt32(archs[i].offset);
			NSString *sliceResult = PatchMachOAtOffset(map, s.st_size, offset, i);
			[result appendFormat:@"%@\n", sliceResult];
		}
	} else if (magic == MH_MAGIC_64) {
		NSString *mainResult = PatchMachOAtOffset(map, s.st_size, 0, 0);
		[result appendFormat:@"%@\n", mainResult];
	} else {
		munmap(map, s.st_size);
		close(fd);
		return [NSString stringWithFormat:@"Unsupported binary format %s: %s", path, strerror(errno)];
	}
	
	munmap(map, s.st_size);
	close(fd);
	return result;
}

NSString *LCThinMachOToARM64(const char *path) {
	int fd = open(path, O_RDWR, 0600);
	if (fd < 0) {
		return [NSString stringWithFormat:@"Failed to open %s: %s", path, strerror(errno)];
	}
	struct stat s = {0};
	if (fstat(fd, &s) != 0 || s.st_size < sizeof(struct fat_header)) {
		close(fd);
		return nil;
	}
	void *map = mmap(NULL, s.st_size, PROT_READ, MAP_SHARED, fd, 0);
	if (map == MAP_FAILED) {
		close(fd);
		return [NSString stringWithFormat:@"Failed to map %s: %s", path, strerror(errno)];
	}

	uint32_t magic = *(uint32_t *)map;
	if (magic != FAT_MAGIC && magic != FAT_CIGAM) {
		// Already thin Mach-O or other file; nothing to do.
		munmap(map, s.st_size);
		close(fd);
		return nil;
	}

	struct fat_header *fat = (struct fat_header *)map;
	uint32_t nfat = (magic == FAT_CIGAM) ? OSSwapInt32(fat->nfat_arch) : fat->nfat_arch;
	struct fat_arch *archs = (struct fat_arch *)((uint8_t *)map + sizeof(struct fat_header));

	uint32_t bestOffset = 0;
	uint32_t bestSize = 0;

	for (uint32_t i = 0; i < nfat; i++) {
		cpu_type_t cputype = (magic == FAT_CIGAM) ? OSSwapInt32(archs[i].cputype) : archs[i].cputype;
		cpu_subtype_t cpusubtype = (magic == FAT_CIGAM) ? OSSwapInt32(archs[i].cpusubtype) : archs[i].cpusubtype;
		uint32_t offset = (magic == FAT_CIGAM) ? OSSwapInt32(archs[i].offset) : archs[i].offset;
		uint32_t size = (magic == FAT_CIGAM) ? OSSwapInt32(archs[i].size) : archs[i].size;

		if ((size_t)offset + (size_t)size > (size_t)s.st_size) {
			continue;
		}

		if (cputype == CPU_TYPE_ARM64) {
			if (cpusubtype == CPU_SUBTYPE_ARM64E) {
				if (bestOffset == 0) {
					bestOffset = offset;
					bestSize = size;
				}
			} else {
				bestOffset = offset;
				bestSize = size;
				break;
			}
		}
	}

	if (bestOffset == 0 || bestSize == 0) {
		munmap(map, s.st_size);
		close(fd);
		return [NSString stringWithFormat:@"No ARM64 slice found in %s", path];
	}

	void *sliceData = malloc(bestSize);
	if (!sliceData) {
		munmap(map, s.st_size);
		close(fd);
		return @"Memory allocation failed during thinning";
	}
	memcpy(sliceData, (uint8_t *)map + bestOffset, bestSize);

	munmap(map, s.st_size);

	if (lseek(fd, 0, SEEK_SET) != 0) {
		free(sliceData);
		close(fd);
		return [NSString stringWithFormat:@"Failed to seek %s: %s", path, strerror(errno)];
	}

	ssize_t written = write(fd, sliceData, bestSize);
	free(sliceData);

	if (written != (ssize_t)bestSize) {
		close(fd);
		return [NSString stringWithFormat:@"Failed to write thinned slice to %s", path];
	}

	if (ftruncate(fd, bestSize) != 0) {
		close(fd);
		return [NSString stringWithFormat:@"Failed to truncate %s: %s", path, strerror(errno)];
	}

	close(fd);
	return nil;
}
