#include "common.h"
#include "json.h"
#include "archo.h"
#include "signing.h"

namespace {
// The mutation and display APIs consume nested signature fields. Bound the
// complete index and each blob before retaining any pointer into mapped bytes.
// This is structural admission only, not cryptographic signature verification.
bool BoundedSignature(const uint8_t* base, uint32_t capacity)
{
    auto word = [base](size_t offset) { uint32_t value; memcpy(&value, base + offset, 4); return LE(value); };
    if (capacity < 12 || word(0) != CSMAGIC_EMBEDDED_SIGNATURE) return false;
    uint32_t length = word(4), count = word(8);
    if (length < 12 || length > capacity || count == 0 || count > 64 || count > (length - 12) / 8) return false;
    uint32_t tableEnd = 12 + count * 8;
    set<uint32_t> types;
    vector<pair<uint32_t, uint32_t>> ranges;
    for (uint32_t index = 0; index < count; ++index) {
        uint32_t type = word(12 + index * 8), offset = word(16 + index * 8);
        if (!types.insert(type).second || offset < tableEnd || offset > length || length - offset < 8) return false;
        uint32_t size = word(offset + 4);
        if (size < 8 || size > length - offset) return false;
        for (const auto& range : ranges) if (offset < range.second && range.first < offset + size) return false;
        ranges.emplace_back(offset, offset + size);
        if (type == CSSLOT_CODEDIRECTORY || (type >= CSSLOT_ALTERNATE_CODEDIRECTORIES && type < CSSLOT_ALTERNATE_CODEDIRECTORIES + 6)) {
            if (word(offset) != CSMAGIC_CODEDIRECTORY || size < 44) return false;
            uint32_t version = word(offset + 8);
            uint32_t header = version >= 0x20600 ? 108 : (version >= 0x20500 ? 96 : (version >= 0x20400 ? 88 :
                (version >= 0x20300 ? 64 : (version >= 0x20200 ? 52 : (version >= 0x20100 ? 48 : 44)))));
            if (size < header) return false;
            uint64_t hashSize = base[offset + 36], hashOffset = word(offset + 16);
            uint64_t special = word(offset + 24), pages = word(offset + 28);
            if (!hashSize || hashSize > 64 || hashOffset > size || special > 128 || special * hashSize > hashOffset ||
                hashOffset - special * hashSize < header || pages * hashSize > size - hashOffset) return false;
            auto stringInBlob = [&](uint32_t start) { return start >= header && start < hashOffset - special * hashSize &&
                memchr(base + offset + start, 0, hashOffset - special * hashSize - start) != NULL; };
            if (!stringInBlob(word(offset + 20))) return false;
            if (version >= 0x20200 && word(offset + 48) && !stringInBlob(word(offset + 48))) return false;
        }
    }
    return types.count(CSSLOT_CODEDIRECTORY) == 1;
}
}

ZArchO::ZArchO()
{
	m_pBase = NULL;
	m_uLength = 0;
	m_uCodeLength = 0;
	m_pSignBase = NULL;
	m_uSignLength = 0;
	m_pHeader = NULL;
	m_uHeaderSize = 0;
	m_uFileType = 0;
	m_bEncrypted = false;
	m_b64Bit = false;
	m_bBigEndian = false;
	m_bEnoughSpace = true;
	m_pCodeSignSegment = NULL;
	m_pLinkEditSegment = NULL;
	m_uLoadCommandsFreeSpace = 0;
    m_uExecSegLimit = 0;
}

bool ZArchO::Init(uint8_t* pBase, uint32_t uLength)
{
	if (NULL == pBase || uLength < sizeof(mach_header) || uLength > 0x80000000U) {
		return false;
	}

	m_pBase = pBase;
	m_uLength = uLength;
	m_uCodeLength = (uLength % 16 == 0) ? uLength : uLength + 16 - (uLength % 16);
	m_pHeader = (mach_header*)m_pBase;
	if (MH_MAGIC != m_pHeader->magic && MH_CIGAM != m_pHeader->magic && MH_MAGIC_64 != m_pHeader->magic && MH_CIGAM_64 != m_pHeader->magic) {
		return false;
	}

	m_b64Bit = (MH_MAGIC_64 == m_pHeader->magic || MH_CIGAM_64 == m_pHeader->magic) ? true : false;
	m_bBigEndian = (MH_CIGAM == m_pHeader->magic || MH_CIGAM_64 == m_pHeader->magic) ? true : false;
    m_uFileType = BO(m_pHeader->filetype);
	m_uHeaderSize = m_b64Bit ? sizeof(mach_header_64) : sizeof(mach_header);
    if (uLength < m_uHeaderSize || BO(m_pHeader->sizeofcmds) > uLength - m_uHeaderSize ||
        BO(m_pHeader->ncmds) > 65536 || BO(m_pHeader->ncmds) > BO(m_pHeader->sizeofcmds) / sizeof(load_command)) return false;
    m_uExecSegLimit = 0;
    m_bEncrypted = false; m_bEnoughSpace = true;
    m_strInfoPlist.clear();
    m_pSignBase = NULL; m_uSignLength = 0;
    m_pCodeSignSegment = NULL; m_pLinkEditSegment = NULL;
    m_uLoadCommandsFreeSpace = 0;
    auto bo64 = [this](uint64_t value) { return m_bBigEndian ? LE(value) : value; };
    auto fileRange = [uLength](uint64_t start, uint64_t length) { return start <= uLength && length <= uLength - start; };
    uint8_t* commandEnd = m_pBase + m_uHeaderSize + BO(m_pHeader->sizeofcmds);
    uint64_t firstSection = uLength;
    bool hasTextSection = false;
    auto sectionRange = [&](uint64_t offset, uint64_t size, uint32_t flags, uint64_t segmentOffset, uint64_t segmentSize) {
        uint32_t type = flags & 0xff;
        if (type == 1 || type == 0xc || type == 0x12 || size == 0) return true; // zero-fill has no file bytes
        if (!fileRange(offset, size) || offset < static_cast<uint64_t>(commandEnd - m_pBase) ||
            offset < segmentOffset || offset - segmentOffset > segmentSize || size > segmentSize - (offset - segmentOffset)) return false;
        firstSection = min(firstSection, offset);
        return true;
    };

	uint8_t* pLoadCommand = m_pBase + m_uHeaderSize;
	for (uint32_t i = 0; i < BO(m_pHeader->ncmds); i++) {
        if (static_cast<size_t>(commandEnd - pLoadCommand) < sizeof(load_command)) return false;
		load_command* plc = (load_command*)pLoadCommand;
        uint32_t commandSize = BO(plc->cmdsize);
        if (commandSize < sizeof(load_command) || commandSize % 4 || commandSize > static_cast<size_t>(commandEnd - pLoadCommand)) return false;
        uint32_t command = BO(plc->cmd);
        // These commands carry C strings used by native mutation/display APIs.
        if (command == LC_LOAD_DYLIB || command == LC_ID_DYLIB || command == LC_LOAD_WEAK_DYLIB ||
            command == LC_REEXPORT_DYLIB || command == LC_LAZY_LOAD_DYLIB || command == LC_LOAD_UPWARD_DYLIB || command == LC_RPATH) {
            uint32_t minimum = command == LC_RPATH ? 12 : sizeof(dylib_command);
            if (commandSize < minimum) return false;
            uint32_t nameOffset; memcpy(&nameOffset, pLoadCommand + 8, 4); nameOffset = BO(nameOffset);
            if (nameOffset < minimum || nameOffset >= commandSize || !memchr(pLoadCommand + nameOffset, 0, commandSize - nameOffset)) return false;
        }
		switch (command) {
		case LC_SEGMENT:
		{
            if (m_b64Bit || commandSize < sizeof(segment_command)) return false;
			segment_command* seglc = (segment_command*)pLoadCommand;
            if (BO(seglc->nsects) > (commandSize - sizeof(segment_command)) / sizeof(section) ||
                !fileRange(BO(seglc->fileoff), BO(seglc->filesize))) return false;
            for (uint32_t j = 0; j < BO(seglc->nsects); ++j) {
                section* sect = reinterpret_cast<section*>(pLoadCommand + sizeof(segment_command) + sizeof(section) * j);
                if (!sectionRange(BO(sect->offset), BO(sect->size), BO(sect->flags), BO(seglc->fileoff), BO(seglc->filesize))) return false;
            }
			if (0 == strncmp("__TEXT", seglc->segname, sizeof(seglc->segname))) {
				m_uExecSegLimit = BO(seglc->vmsize);
				for (uint32_t j = 0; j < BO(seglc->nsects); j++) {
					section* sect = (section*)((pLoadCommand + sizeof(segment_command)) + sizeof(section) * j);
					if (0 == strncmp("__text", sect->sectname, sizeof(sect->sectname))) {
                        hasTextSection = BO(sect->size) > 0;
					} else if (0 == strncmp("__info_plist", sect->sectname, sizeof(sect->sectname))) {
                        if (!fileRange(BO(sect->offset), BO(sect->size)) || BO(sect->size) > 1024 * 1024 || !m_strInfoPlist.empty()) return false;
						m_strInfoPlist.append((const char*)m_pBase + BO(sect->offset), BO(sect->size));
					}
				}
			} else if (0 == strncmp("__LINKEDIT", seglc->segname, sizeof(seglc->segname))) {
				m_pLinkEditSegment = pLoadCommand;
			}
		}
		break;
		case LC_SEGMENT_64:
		{
            if (!m_b64Bit || commandSize < sizeof(segment_command_64)) return false;
			segment_command_64* seglc = (segment_command_64*)pLoadCommand;
            if (BO(seglc->nsects) > (commandSize - sizeof(segment_command_64)) / sizeof(section_64) ||
                !fileRange(bo64(seglc->fileoff), bo64(seglc->filesize))) return false;
            for (uint32_t j = 0; j < BO(seglc->nsects); ++j) {
                section_64* sect = reinterpret_cast<section_64*>(pLoadCommand + sizeof(segment_command_64) + sizeof(section_64) * j);
                if (!sectionRange(BO(sect->offset), bo64(sect->size), BO(sect->flags), bo64(seglc->fileoff), bo64(seglc->filesize))) return false;
            }
			if (0 == strncmp("__TEXT", seglc->segname, sizeof(seglc->segname))) {
				m_uExecSegLimit = bo64(seglc->vmsize);
				for (uint32_t j = 0; j < BO(seglc->nsects); j++) {
					section_64* sect = (section_64*)((pLoadCommand + sizeof(segment_command_64)) + sizeof(section_64) * j);
					if (0 == strncmp("__text", sect->sectname, sizeof(sect->sectname))) {
                        hasTextSection = bo64(sect->size) > 0;
					} else if (0 == strncmp("__info_plist", sect->sectname, sizeof(sect->sectname))) {
                        if (!fileRange(BO(sect->offset), bo64(sect->size)) || bo64(sect->size) > 1024 * 1024 || !m_strInfoPlist.empty()) return false;
						m_strInfoPlist.append((const char*)m_pBase + BO(sect->offset), static_cast<size_t>(bo64(sect->size)));
					}
				}
			} else if (0 == strncmp("__LINKEDIT", seglc->segname, sizeof(seglc->segname))) {
				m_pLinkEditSegment = pLoadCommand;
			}
		}
		break;
		case LC_ENCRYPTION_INFO:
		case LC_ENCRYPTION_INFO_64:
		{
            if (commandSize < sizeof(encryption_info_command)) return false;
			encryption_info_command* crypt_cmd = (encryption_info_command*)pLoadCommand;
            if (!fileRange(BO(crypt_cmd->cryptoff), BO(crypt_cmd->cryptsize))) return false;
			if (BO(crypt_cmd->cryptid) >= 1) {
				m_bEncrypted = true;
			}
		}
		break;
		case LC_CODE_SIGNATURE:
		{
            if (commandSize != sizeof(codesignature_command) || m_pCodeSignSegment) return false;
			codesignature_command* pcslc = (codesignature_command*)pLoadCommand;
            if (BO(pcslc->dataoff) < m_uHeaderSize + BO(m_pHeader->sizeofcmds) ||
                BO(pcslc->datasize) < 12 || !fileRange(BO(pcslc->dataoff), BO(pcslc->datasize))) return false;
            uint32_t signMagic, signLength;
            memcpy(&signMagic, m_pBase + BO(pcslc->dataoff), 4);
            memcpy(&signLength, m_pBase + BO(pcslc->dataoff) + 4, 4);
            bool emptyReservation = signMagic == 0 && signLength == 0 &&
                std::all_of(m_pBase + BO(pcslc->dataoff), m_pBase + BO(pcslc->dataoff) + BO(pcslc->datasize), [](uint8_t byte) { return byte == 0; });
            if (!emptyReservation && !BoundedSignature(m_pBase + BO(pcslc->dataoff), BO(pcslc->datasize))) return false;
			m_pCodeSignSegment = pLoadCommand;
			m_uCodeLength = BO(pcslc->dataoff);
			m_pSignBase = m_pBase + m_uCodeLength;
			m_uSignLength = ZSign::GetCodeSignatureLength(m_pSignBase);
		}
		break;
		}

		pLoadCommand += BO(plc->cmdsize);
	}

    if (pLoadCommand != commandEnd) return false;
    if (hasTextSection && firstSection >= static_cast<uint64_t>(commandEnd - m_pBase))
        m_uLoadCommandsFreeSpace = static_cast<uint32_t>(firstSection - (commandEnd - m_pBase));
    return true;
}

const char* ZArchO::GetArch(int cpuType, int cpuSubType)
{
	switch (cpuType) {
	case CPU_TYPE_ARM:
	{
		switch (cpuSubType) {
		case CPU_SUBTYPE_ARM_V6:
			return "armv6";
			break;
		case CPU_SUBTYPE_ARM_V7:
			return "armv7";
			break;
		case CPU_SUBTYPE_ARM_V7S:
			return "armv7s";
			break;
		case CPU_SUBTYPE_ARM_V7K:
			return "armv7k";
			break;
		case CPU_SUBTYPE_ARM_V8:
			return "armv8";
			break;
		}
	}
	break;
	case CPU_TYPE_ARM64:
	{
		switch (cpuSubType) {
		case CPU_SUBTYPE_ARM64_ALL:
			return "arm64";
			break;
		case CPU_SUBTYPE_ARM64_V8:
			return "arm64v8";
			break;
		case 2:
			return "arm64e";
			break;
		}
	}
	break;
	case CPU_TYPE_ARM64_32:
	{
		switch (cpuSubType) {
		case CPU_SUBTYPE_ARM64_ALL:
			return "arm64_32";
			break;
		case CPU_SUBTYPE_ARM64_32_V8:
			return "arm64e_32";
			break;
		}
	}
	break;
	case CPU_TYPE_X86:
	{
		return "x86_32";
	}
	break;
	case CPU_TYPE_X86_64:
	{
		return "x86_64";
	}
	break;
	}
	return "unknown";
}

const char* ZArchO::GetFileType(uint32_t uFileType)
{
	switch (uFileType) {
	case MH_OBJECT:
		return "MH_OBJECT";
		break;
	case MH_EXECUTE:
		return "MH_EXECUTE";
		break;
	case MH_FVMLIB:
		return "MH_FVMLIB";
		break;
	case MH_CORE:
		return "MH_CORE";
		break;
	case MH_PRELOAD:
		return "MH_PRELOAD";
		break;
	case MH_DYLIB:
		return "MH_DYLIB";
		break;
	case MH_DYLINKER:
		return "MH_DYLINKER";
		break;
	case MH_BUNDLE:
		return "MH_BUNDLE";
		break;
	case MH_DYLIB_STUB:
		return "MH_DYLIB_STUB";
		break;
	case MH_DSYM:
		return "MH_DSYM";
		break;
	case MH_KEXT_BUNDLE:
		return "MH_KEXT_BUNDLE";
		break;
	}
	return "MH_UNKNOWN";
}

uint32_t ZArchO::BO(uint32_t uValue)
{
	return m_bBigEndian ? LE(uValue) : uValue;
}

bool ZArchO::IsExecute()
{
	if (NULL != m_pHeader) {
		return (MH_EXECUTE == BO(m_pHeader->filetype));
	}
	return false;
}

bool ZArchO::IsSigned() const 
{
	if (NULL == m_pSignBase || m_uSignLength <= 0) {
		ZLog::PrintV("File is not signed.\n");
		return false;
	}
	
	ZLog::PrintV("File is signed.\n");
	return true;
}

void ZArchO::PrintInfo()
{
	if (NULL == m_pHeader) {
		return;
	}

	ZLog::Print("------------------------------------------------------------------\n");
	ZLog::Print(">>> MachO Info: \n");
	ZLog::PrintV("\tFileType: \t%s\n", GetFileType(BO(m_pHeader->filetype)));
	ZLog::PrintV("\tTotalSize: \t%u (%s)\n", m_uLength, ZUtil::FormatSize(m_uLength).c_str());
	ZLog::PrintV("\tPlatform: \t%u\n", m_b64Bit ? 64 : 32);
	ZLog::PrintV("\tCPUArch: \t%s\n", GetArch(BO(m_pHeader->cputype), BO(m_pHeader->cpusubtype)));
	ZLog::PrintV("\tCPUType: \t0x%x\n", BO(m_pHeader->cputype));
	ZLog::PrintV("\tCPUSubType: \t0x%x\n", BO(m_pHeader->cpusubtype));
	ZLog::PrintV("\tBigEndian: \t%d\n", m_bBigEndian);
	ZLog::PrintV("\tEncrypted: \t%d\n", m_bEncrypted);
	ZLog::PrintV("\tCommandCount: \t%d\n", BO(m_pHeader->ncmds));
	ZLog::PrintV("\tCodeLength: \t%d (%s)\n", m_uCodeLength, ZUtil::FormatSize(m_uCodeLength).c_str());
	ZLog::PrintV("\tSignLength: \t%d (%s)\n", m_uSignLength, ZUtil::FormatSize(m_uSignLength).c_str());
	ZLog::PrintV("\tSpareLength: \t%d (%s)\n", m_uLength - m_uCodeLength - m_uSignLength, ZUtil::FormatSize(m_uLength - m_uCodeLength - m_uSignLength).c_str());

	uint8_t* pLoadCommand = m_pBase + m_uHeaderSize;
	for (uint32_t i = 0; i < BO(m_pHeader->ncmds); i++) {
		load_command* plc = (load_command*)pLoadCommand;
		if (LC_VERSION_MIN_IPHONEOS == BO(plc->cmd)) {
			ZLog::PrintV("\tMIN_IPHONEOS: \t0x%x\n", *((uint32_t*)(pLoadCommand + sizeof(load_command))));
		} else if (LC_RPATH == BO(plc->cmd)) {
			ZLog::PrintV("\tLC_RPATH: \t%s\n", (char*)(pLoadCommand + sizeof(load_command) + 4));
		}
		pLoadCommand += BO(plc->cmdsize);
	}

	bool bHasWeakDylib = false;
	ZLog::PrintV("\tLC_LOAD_DYLIB: \n");
	pLoadCommand = m_pBase + m_uHeaderSize;
	for (uint32_t i = 0; i < BO(m_pHeader->ncmds); i++) {
		load_command* plc = (load_command*)pLoadCommand;
		if (LC_LOAD_DYLIB == BO(plc->cmd)) {
			dylib_command* dlc = (dylib_command*)pLoadCommand;
			const char* szDylib = (const char*)(pLoadCommand + BO(dlc->dylib.name.offset));
			ZLog::PrintV("\t\t\t%s\n", szDylib);
		} else if (LC_LOAD_WEAK_DYLIB == BO(plc->cmd)) {
			bHasWeakDylib = true;
		}
		pLoadCommand += BO(plc->cmdsize);
	}

	if (bHasWeakDylib) {
		ZLog::PrintV("\tLC_LOAD_WEAK_DYLIB: \n");
		pLoadCommand = m_pBase + m_uHeaderSize;
		for (uint32_t i = 0; i < BO(m_pHeader->ncmds); i++) {
			load_command* plc = (load_command*)pLoadCommand;
			if (LC_LOAD_WEAK_DYLIB == BO(plc->cmd)) {
				dylib_command* dlc = (dylib_command*)pLoadCommand;
				const char* szDylib = (const char*)(pLoadCommand + BO(dlc->dylib.name.offset));
				ZLog::PrintV("\t\t\t%s (weak)\n", szDylib);
			}
			pLoadCommand += BO(plc->cmdsize);
		}
	}

	if (!m_strInfoPlist.empty()) {
		ZLog::Print("\n>>> Embedded Info.plist: \n");
		ZLog::PrintV("\tlength: \t%lu\n", m_strInfoPlist.size());

		string strInfoPlist = m_strInfoPlist;
		ZUtil::StringReplace(strInfoPlist, "\n", "\n\t\t\t");
		ZLog::PrintV("\tcontent: \t%s\n", strInfoPlist.c_str());

		ZSHA::PrintData1("\tSHA-1:  \t", m_strInfoPlist);
		ZSHA::PrintData256("\tSHA-256:\t", m_strInfoPlist);
	}

	if (NULL == m_pSignBase || m_uSignLength <= 0) {
		ZLog::Warn(">>> Can't find CodeSignature segment!\n");
	} else {
		ZSign::ParseCodeSignature(m_pSignBase);
	}

	ZLog::Print("------------------------------------------------------------------\n");
}

bool ZArchO::BuildCodeSignature(ZSignAsset* pSignAsset, 
	bool bForce, 
	const string& strBundleId, 
	const string& strInfoSHA1, 
	const string& strInfoSHA256, 
	const string& strCodeResourcesSHA1, 
	const string& strCodeResourcesSHA256, 
	string& strOutput)
{
	string strRequirementsSlot;
	string strEntitlementsSlot;
	string strDerEntitlementsSlot;

	string strEmptyEntitlements = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n<plist version=\"1.0\">\n<dict/>\n</plist>\n";
    if (!pSignAsset || !ZSign::SlotBuildRequirements(strBundleId, pSignAsset->m_strSubjectCN, strRequirementsSlot)) return false;
    if (!ZSign::SlotBuildEntitlements(IsExecute() ? pSignAsset->m_strEntitleData : strEmptyEntitlements, strEntitlementsSlot)) return false;
    if (IsExecute() && !ZSign::SlotBuildDerEntitlements(pSignAsset->m_strEntitleData, strDerEntitlementsSlot)) return false;

	string strRequirementsSlotSHA1;
	string strRequirementsSlotSHA256;
	if (strRequirementsSlot.empty()) { //empty
		strRequirementsSlotSHA1.append(20, 0);
		strRequirementsSlotSHA256.append(32, 0);
	} else {
		ZSHA::SHA(strRequirementsSlot, strRequirementsSlotSHA1, strRequirementsSlotSHA256);
	}

	string strEntitlementsSlotSHA1;
	string strEntitlementsSlotSHA256;
	if (strEntitlementsSlot.empty()) { //empty
		strEntitlementsSlotSHA1.append(20, 0);
		strEntitlementsSlotSHA256.append(32, 0);
	} else {
		ZSHA::SHA(strEntitlementsSlot, strEntitlementsSlotSHA1, strEntitlementsSlotSHA256);
	}

	string strDerEntitlementsSlotSHA1;
	string strDerEntitlementsSlotSHA256;
	if (strDerEntitlementsSlot.empty()) { //empty
		strDerEntitlementsSlotSHA1.append(20, 0);
		strDerEntitlementsSlotSHA256.append(32, 0);
	} else {
		ZSHA::SHA(strDerEntitlementsSlot, strDerEntitlementsSlotSHA1, strDerEntitlementsSlotSHA256);
	}

	uint8_t* pCodeSlots1Data = NULL;
	uint8_t* pCodeSlots256Data = NULL;
	uint32_t uCodeSlots1DataLength = 0;
	uint32_t uCodeSlots256DataLength = 0;
    // Every run hashes the actual code bytes, even when resource caching is enabled.
    // Old CodeDirectory page hashes are untrusted and may describe pre-mutation code.

	uint64_t uExecSegFlags = 0;
	if (MH_EXECUTE == m_uFileType) {
        uExecSegFlags = CS_EXECSEG_MAIN_BINARY;
	}

    jvalue requestedEntitlements;
    if (MH_EXECUTE == m_uFileType && requestedEntitlements.read_plist(pSignAsset->m_strEntitleData) &&
        requestedEntitlements["get-task-allow"].is_bool() && requestedEntitlements["get-task-allow"].as_bool()) {
        uExecSegFlags |= CS_EXECSEG_MAIN_BINARY | CS_EXECSEG_ALLOW_UNSIGNED;
    }

	string strCodeDirectorySlot;
	string strAltnateCodeDirectorySlot;
	if (!pSignAsset->m_bSHA256Only) {
        if (!ZSign::SlotBuildCodeDirectory(false,
			m_pBase,
			m_uCodeLength,
			pCodeSlots1Data,
			uCodeSlots1DataLength,
			m_uExecSegLimit,
			uExecSegFlags,
			strBundleId,
			pSignAsset->m_strTeamId,
			strInfoSHA1,
			strRequirementsSlotSHA1,
			strCodeResourcesSHA1,
			strEntitlementsSlotSHA1,
			strDerEntitlementsSlotSHA1,
			IsExecute(),
			pSignAsset->m_bAdhoc,
            strCodeDirectorySlot)) return false;
	}

    if (!ZSign::SlotBuildCodeDirectory(true,
		m_pBase,
		m_uCodeLength,
		pCodeSlots256Data,
		uCodeSlots256DataLength,
		m_uExecSegLimit,
		uExecSegFlags,
		strBundleId,
		pSignAsset->m_strTeamId,
		strInfoSHA256,
		strRequirementsSlotSHA256,
		strCodeResourcesSHA256,
		strEntitlementsSlotSHA256,
		strDerEntitlementsSlotSHA256,
		IsExecute(),
		pSignAsset->m_bAdhoc,
        strAltnateCodeDirectorySlot)) return false;
	if (pSignAsset->m_bSHA256Only) {
		// SHA256-based code directory is usually the alternate; however, make it the primary (and only)
		// code directory if `m_bUseSHA256Only == true`.
		strAltnateCodeDirectorySlot.swap(strCodeDirectorySlot);
	}

	string strCMSSignatureSlot;
	if (!pSignAsset->m_bAdhoc) { //adhoc remove cms signature slot
        if (!ZSign::SlotBuildCMSSignature(pSignAsset, strCodeDirectorySlot, strAltnateCodeDirectorySlot, strCMSSignatureSlot)) return false;
	}

	uint32_t uCodeDirectorySlotLength = (uint32_t)strCodeDirectorySlot.size();
	uint32_t uRequirementsSlotLength = (uint32_t)strRequirementsSlot.size();
	uint32_t uEntitlementsSlotLength = (uint32_t)strEntitlementsSlot.size();
	uint32_t uDerEntitlementsLength = (uint32_t)strDerEntitlementsSlot.size();
	uint32_t uAltnateCodeDirectorySlotLength = (uint32_t)strAltnateCodeDirectorySlot.size();
	uint32_t uCMSSignatureSlotLength = (uint32_t)strCMSSignatureSlot.size();

	uint32_t uCodeSignBlobCount = 0;
	uCodeSignBlobCount += (uCodeDirectorySlotLength > 0) ? 1 : 0;
	uCodeSignBlobCount += (uRequirementsSlotLength > 0) ? 1 : 0;
	uCodeSignBlobCount += (uEntitlementsSlotLength > 0) ? 1 : 0;
	uCodeSignBlobCount += (uDerEntitlementsLength > 0) ? 1 : 0;
	uCodeSignBlobCount += (uAltnateCodeDirectorySlotLength > 0) ? 1 : 0;
	uCodeSignBlobCount += (uCMSSignatureSlotLength > 0) ? 1 : 0;

	uint32_t uSuperBlobHeaderLength = sizeof(CS_SuperBlob) + uCodeSignBlobCount * sizeof(CS_BlobIndex);
	uint32_t uCodeSignLength = uSuperBlobHeaderLength +
		uCodeDirectorySlotLength +
		uRequirementsSlotLength +
		uEntitlementsSlotLength +
		uDerEntitlementsLength +
		uAltnateCodeDirectorySlotLength +
		uCMSSignatureSlotLength;

	vector<CS_BlobIndex> arrBlobIndexes;
	if (uCodeDirectorySlotLength > 0) {
		CS_BlobIndex blob;
		blob.type = BE((uint32_t)CSSLOT_CODEDIRECTORY);
		blob.offset = BE(uSuperBlobHeaderLength);
		arrBlobIndexes.push_back(blob);
	}

	if (uRequirementsSlotLength > 0) {
		CS_BlobIndex blob;
		blob.type = BE((uint32_t)CSSLOT_REQUIREMENTS);
		blob.offset = BE(uSuperBlobHeaderLength + uCodeDirectorySlotLength);
		arrBlobIndexes.push_back(blob);
	}

	if (uEntitlementsSlotLength > 0) {
		CS_BlobIndex blob;
		blob.type = BE((uint32_t)CSSLOT_ENTITLEMENTS);
		blob.offset = BE(uSuperBlobHeaderLength + uCodeDirectorySlotLength + uRequirementsSlotLength);
		arrBlobIndexes.push_back(blob);
	}

	if (uDerEntitlementsLength > 0) {
		CS_BlobIndex blob;
		blob.type = BE((uint32_t)CSSLOT_DER_ENTITLEMENTS);
		blob.offset = BE(uSuperBlobHeaderLength + uCodeDirectorySlotLength + uRequirementsSlotLength + uEntitlementsSlotLength);
		arrBlobIndexes.push_back(blob);
	}

	if (uAltnateCodeDirectorySlotLength > 0) {
		CS_BlobIndex blob;
		blob.type = BE((uint32_t)CSSLOT_ALTERNATE_CODEDIRECTORIES);
		blob.offset = BE(uSuperBlobHeaderLength + uCodeDirectorySlotLength + uRequirementsSlotLength + uEntitlementsSlotLength + uDerEntitlementsLength);
		arrBlobIndexes.push_back(blob);
	}

	if (uCMSSignatureSlotLength > 0) {
		CS_BlobIndex blob;
		blob.type = BE((uint32_t)CSSLOT_SIGNATURESLOT);
		blob.offset = BE(uSuperBlobHeaderLength + uCodeDirectorySlotLength + uRequirementsSlotLength + uEntitlementsSlotLength + uDerEntitlementsLength + uAltnateCodeDirectorySlotLength);
		arrBlobIndexes.push_back(blob);
	}

	CS_SuperBlob superblob;
	superblob.magic = BE((uint32_t)CSMAGIC_EMBEDDED_SIGNATURE);
	superblob.length = BE(uCodeSignLength);
	superblob.count = BE(uCodeSignBlobCount);

	strOutput.clear();
	strOutput.reserve(uCodeSignLength);
	strOutput.append((const char*)&superblob, sizeof(superblob));
	for (size_t i = 0; i < arrBlobIndexes.size(); i++) {
		CS_BlobIndex& blob = arrBlobIndexes[i];
		strOutput.append((const char*)&blob, sizeof(blob));
	}
	strOutput += strCodeDirectorySlot;
	strOutput += strRequirementsSlot;
	strOutput += strEntitlementsSlot;
	strOutput += strDerEntitlementsSlot;
	strOutput += strAltnateCodeDirectorySlot;
	strOutput += strCMSSignatureSlot;

	if (ZLog::IsDebug()) {
		ZFile::WriteFile("./.zsign_debug/Requirements.slot.new", strRequirementsSlot);
		ZFile::WriteFile("./.zsign_debug/Entitlements.slot.new", strEntitlementsSlot);
		ZFile::WriteFile("./.zsign_debug/Entitlements.der.slot.new", strDerEntitlementsSlot);
		ZFile::WriteFile("./.zsign_debug/Entitlements.plist.new", strEntitlementsSlot.data() + 8, strEntitlementsSlot.size() - 8);
		ZFile::WriteFile("./.zsign_debug/CodeDirectory_SHA1.slot.new", strCodeDirectorySlot);
		ZFile::WriteFile("./.zsign_debug/CodeDirectory_SHA256.slot.new", strAltnateCodeDirectorySlot);
		ZFile::WriteFile("./.zsign_debug/CMSSignature.slot.new", strCMSSignatureSlot);
		ZFile::WriteFile("./.zsign_debug/CMSSignature.der.new", strCMSSignatureSlot.data() + 8, strCMSSignatureSlot.size() - 8);
		ZFile::WriteFile("./.zsign_debug/CodeSignature.blob.new", strOutput);
	}

	return true;
}

bool ZArchO::Sign(ZSignAsset* pSignAsset, 
					bool bForce, 
					const string& strBundleId, 
					const string& strInfoSHA1, 
					const string& strInfoSHA256, 
					const string& strCodeResourcesData)
{
	if (NULL == m_pSignBase) {
		m_bEnoughSpace = false;
		ZLog::Warn(">>> Can't find CodeSignature segment!\n");
		return false;
	}

	string strCodeResourcesSHA1;
	string strCodeResourcesSHA256;
	if (strCodeResourcesData.empty()) {
		strCodeResourcesSHA1.append(20, 0);
		strCodeResourcesSHA256.append(32, 0);
	} else {
		ZSHA::SHA(strCodeResourcesData, strCodeResourcesSHA1, strCodeResourcesSHA256);
	}

	string strCodeSignBlob;
    if (!BuildCodeSignature(pSignAsset, bForce, strBundleId, strInfoSHA1, strInfoSHA256, strCodeResourcesSHA1, strCodeResourcesSHA256, strCodeSignBlob)) return false;
	if (strCodeSignBlob.empty()) {
		ZLog::Error(">>> Build CodeSignature failed!\n");
		return false;
	}

	int nSpaceLength = (int)m_uLength - (int)m_uCodeLength - (int)strCodeSignBlob.size();
	if (nSpaceLength < 0) {
		m_bEnoughSpace = false;
		ZLog::WarnV(">>> No enough CodeSignature space (now: %d, need: %d).\n", (int)m_uLength - (int)m_uCodeLength, (int)strCodeSignBlob.size());
		return false;
	}

	memcpy(m_pBase + m_uCodeLength, strCodeSignBlob.data(), strCodeSignBlob.size());
    // Do not retain stale signature/entitlement bytes in the reserved region.
    memset(m_pBase + m_uCodeLength + strCodeSignBlob.size(), 0, nSpaceLength);
	return true;
}

uint32_t ZArchO::ReallocCodeSignSpace(const string& strNewFile)
{
	ZFile::RemoveFile(strNewFile.c_str());

	uint32_t uNewLength = m_uCodeLength + ZUtil::ByteAlign(((m_uCodeLength / 4096) + 1) * (20 + 32), 4096) + 16384; //16K May Be Enough
	if (NULL == m_pLinkEditSegment || uNewLength <= m_uLength) {
		return 0;
	}

	load_command* pseglc = (load_command*)m_pLinkEditSegment;
	switch (BO(pseglc->cmd)) {
	case LC_SEGMENT:
	{
		segment_command* seglc = (segment_command*)m_pLinkEditSegment;
		seglc->vmsize = ZUtil::ByteAlign(BO(seglc->vmsize) + (uNewLength - m_uLength), 4096);
		seglc->vmsize = BO(seglc->vmsize);
		seglc->filesize = uNewLength - BO(seglc->fileoff);
		seglc->filesize = BO(seglc->filesize);
	}
	break;
	case LC_SEGMENT_64:
	{
        segment_command_64* seglc = reinterpret_cast<segment_command_64*>(m_pLinkEditSegment);
        auto bo64 = [this](uint64_t value) { return m_bBigEndian ? LE(value) : value; };
        uint64_t vm = bo64(seglc->vmsize), fileOffset = bo64(seglc->fileoff);
        uint64_t delta = uNewLength - m_uLength;
        if (vm > UINT64_MAX - delta - 4095 || fileOffset > uNewLength) return 0;
        seglc->vmsize = bo64((vm + delta + 4095) & ~uint64_t(4095));
        seglc->filesize = bo64(uNewLength - fileOffset);
	}
	break;
	}

	codesignature_command* pcslc = (codesignature_command*)m_pCodeSignSegment;
	if (NULL == pcslc) {
		if (m_uLoadCommandsFreeSpace < sizeof(codesignature_command)) {
			ZLog::Error(">>> Can't find free space of LoadCommands for CodeSignature!\n");
			return 0;
		}

		pcslc = (codesignature_command*)(m_pBase + m_uHeaderSize + BO(m_pHeader->sizeofcmds));
		pcslc->cmd = BO(LC_CODE_SIGNATURE);
		pcslc->cmdsize = BO((uint32_t)sizeof(codesignature_command));
		pcslc->dataoff = BO(m_uCodeLength);
		m_pHeader->ncmds = BO(BO(m_pHeader->ncmds) + 1);
		m_pHeader->sizeofcmds = BO(BO(m_pHeader->sizeofcmds) + sizeof(codesignature_command));
	}
	pcslc->datasize = BO(uNewLength - m_uCodeLength);

	if (!ZFile::AppendFile(strNewFile.c_str(), (const char*)m_pBase, m_uLength)) {
		return 0;
	}

	string strPadding;
	strPadding.append(uNewLength - m_uLength, 0);
	if (!ZFile::AppendFile(strNewFile.c_str(), strPadding)) {
		ZFile::RemoveFile(strNewFile.c_str());
		return 0;
	}

	return uNewLength;
}

bool ZArchO::InjectDylib(bool bWeakInject, const char* szDylibFile)
{
    if (NULL == m_pHeader || NULL == szDylibFile || !szDylibFile[0]) return false;

	uint8_t* pLoadCommand = m_pBase + m_uHeaderSize;
	for (uint32_t i = 0; i < BO(m_pHeader->ncmds); i++) {
		load_command* plc = (load_command*)pLoadCommand;
		uint32_t uLoadType = BO(plc->cmd);
		if (LC_LOAD_DYLIB == uLoadType || LC_LOAD_WEAK_DYLIB == uLoadType) {
			dylib_command* dlc = (dylib_command*)pLoadCommand;
			const char* szDylib = (const char*)(pLoadCommand + BO(dlc->dylib.name.offset));
			if (0 == strcmp(szDylib, szDylibFile)) {
				if ((bWeakInject && (LC_LOAD_WEAK_DYLIB != uLoadType)) || (!bWeakInject && (LC_LOAD_DYLIB != uLoadType))) {
					dlc->cmd = BO((uint32_t)(bWeakInject ? LC_LOAD_WEAK_DYLIB : LC_LOAD_DYLIB));
					const char* oldLoadType = bWeakInject ? "LC_LOAD_DYLIB" : "LC_LOAD_WEAK_DYLIB";
					const char* newLoadType = bWeakInject ? "LC_LOAD_WEAK_DYLIB" : "LC_LOAD_DYLIB";
					ZLog::WarnV(">>>\t\t %s -> %s\n", oldLoadType, newLoadType);
				}
				return true;
			}
		}
		pLoadCommand += BO(plc->cmdsize);
	}

	uint32_t uDylibFileLength = (uint32_t)strlen(szDylibFile);
	uint32_t uDylibFilePadding = (8 - uDylibFileLength % 8);
	uint32_t uDylibCommandSize = sizeof(dylib_command) + uDylibFileLength + uDylibFilePadding;
    uint64_t commandEnd = uint64_t(m_uHeaderSize) + BO(m_pHeader->sizeofcmds);
    if (m_uLoadCommandsFreeSpace < uDylibCommandSize || commandEnd > m_uLength ||
        uDylibCommandSize > m_uLength - commandEnd ||
        !std::all_of(m_pBase + commandEnd, m_pBase + commandEnd + uDylibCommandSize, [](uint8_t byte) { return byte == 0; })) {
		ZLog::Error(">>> Can't find free space of LoadCommands for LC_LOAD_DYLIB or LC_LOAD_WEAK_DYLIB!\n");
		return false;
	}

	//add
	dylib_command* dlc = (dylib_command*)(m_pBase + m_uHeaderSize + BO(m_pHeader->sizeofcmds));
	dlc->cmd = BO((uint32_t)(bWeakInject ? LC_LOAD_WEAK_DYLIB : LC_LOAD_DYLIB));
	dlc->cmdsize = BO(uDylibCommandSize);
	dlc->dylib.name.offset = BO((uint32_t)sizeof(dylib_command));
	dlc->dylib.timestamp = BO((uint32_t)2);
	dlc->dylib.current_version = 0;
	dlc->dylib.compatibility_version = 0;

	string strDylibFile = szDylibFile;
	strDylibFile.append(uDylibFilePadding, 0);

	uint8_t* pDylibFile = (uint8_t*)dlc + sizeof(dylib_command);
	memcpy(pDylibFile, strDylibFile.data(), strDylibFile.size());

	m_pHeader->ncmds = BO(BO(m_pHeader->ncmds) + 1);
	m_pHeader->sizeofcmds = BO(BO(m_pHeader->sizeofcmds) + uDylibCommandSize);
    m_uLoadCommandsFreeSpace -= uDylibCommandSize;

	return true;
}

void ZArchO::RemoveDylibs(set<string> setDylibs)
{
	uint8_t* pLoadCommand = m_pBase + m_uHeaderSize;
	uint32_t old_load_command_size = m_pHeader->sizeofcmds;
	uint8_t* new_load_command_data = (uint8_t*)malloc(old_load_command_size);
	if (NULL == new_load_command_data) {
		return;
	}

	memset(new_load_command_data, 0, old_load_command_size);
	uint32_t new_load_command_size = 0;
	uint32_t clear_num = 0;
	uint32_t clear_data_size = 0;
	for (uint32_t i = 0; i < BO(m_pHeader->ncmds); i++) {
		load_command* plc = (load_command*)pLoadCommand;
		uint32_t load_command_size = BO(plc->cmdsize);
		if (LC_LOAD_DYLIB == BO(plc->cmd) || LC_LOAD_WEAK_DYLIB == BO(plc->cmd)) {
			dylib_command* dlc = (dylib_command*)pLoadCommand;
			const char* szDylib = (const char*)(pLoadCommand + BO(dlc->dylib.name.offset));
			string dylibName = szDylib;
			if (setDylibs.count(dylibName) > 0) {
				ZLog::PrintV("\t\t\t%s\tclear\n", szDylib);
				clear_num++;
				clear_data_size += load_command_size;
				pLoadCommand += BO(plc->cmdsize);
				continue;
			}
			ZLog::PrintV("\t\t\t%s\n", szDylib);
		}
		new_load_command_size += load_command_size;
		memcpy(new_load_command_data, pLoadCommand, load_command_size);
		new_load_command_data += load_command_size;
		pLoadCommand += BO(plc->cmdsize);
	}
	pLoadCommand -= m_pHeader->sizeofcmds;

	m_pHeader->ncmds -= clear_num;
	m_pHeader->sizeofcmds -= clear_data_size;
	new_load_command_data -= new_load_command_size;
	memset(pLoadCommand, 0, old_load_command_size);
	memcpy(pLoadCommand, new_load_command_data, new_load_command_size);
	free(new_load_command_data);
}

std::vector<std::string> ZArchO::ListDylibs() {
	std::vector<std::string> dylibList;
	uint8_t *pLoadCommand = m_pBase + m_uHeaderSize;
	
	for (uint32_t i = 0; i < BO(m_pHeader->ncmds); i++) {
		load_command *plc = (load_command *)pLoadCommand;
		if (LC_LOAD_DYLIB == BO(plc->cmd) || LC_LOAD_WEAK_DYLIB == BO(plc->cmd)) {
			dylib_command *dlc = (dylib_command *)pLoadCommand;
			const char *szDyLib = (const char *)(pLoadCommand + BO(dlc->dylib.name.offset));
			dylibList.push_back(std::string(szDyLib));
		}
		pLoadCommand += BO(plc->cmdsize);
	}
	
	return dylibList;
}

bool ZArchO::ChangeDylibPath(const char *oldPath, const char *newPath) {
	if (NULL == m_pHeader) {
		return false;
	}
	
	uint8_t *pLoadCommand = m_pBase + m_uHeaderSize;
	bool pathChanged = false;
	uint32_t oldPathLength = (uint32_t)strlen(oldPath);
	uint32_t newPathLength = (uint32_t)strlen(newPath);
	uint32_t oldPathPadding = (8 - oldPathLength % 8) % 8;
	uint32_t newPathPadding = (8 - newPathLength % 8) % 8;
	uint32_t newLoadCommandSize = 0;
	
	for (uint32_t i = 0; i < BO(m_pHeader->ncmds); i++) {
		load_command *plc = (load_command *)pLoadCommand;
		uint32_t uLoadType = BO(plc->cmd);
		
		if (LC_LOAD_DYLIB == uLoadType || LC_LOAD_WEAK_DYLIB == uLoadType) {
			dylib_command *dlc = (dylib_command *)pLoadCommand;
			const char *szDyLib = (const char *)(pLoadCommand + BO(dlc->dylib.name.offset));
			
			if (strcmp(szDyLib, oldPath) == 0) {
				uint32_t dylibPathOffset = sizeof(dylib_command);
				uint32_t dylibPathSize = newPathLength + newPathPadding;
				if (dylibPathOffset + dylibPathSize > BO(plc->cmdsize)) {
					ZLog::Error(">>> Insufficient space to update dylib path!\n");
					return false;
				}
				
				memcpy(pLoadCommand + dylibPathOffset, newPath, newPathLength);
				memset(pLoadCommand + dylibPathOffset + newPathLength, 0, newPathPadding);
				
				ZLog::PrintV(">>> Dylib Path Changed: %s -> %s\n", oldPath, newPath);
				
				pathChanged = true;
			}
		}
		
		pLoadCommand += BO(plc->cmdsize);
	}
	
	if (!pathChanged) {
		ZLog::PrintV(">>> Old Dylib Path Not Found: %s\n", oldPath);
	}
	
	return pathChanged;
}
