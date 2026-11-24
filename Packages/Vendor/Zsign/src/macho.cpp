#include "common.h"
#include "json.h"
#include "mach-o.h"
#include "openssl.h"
#include "signing.h"
#include "macho.h"

ZMachO::ZMachO()
{
	m_pBase = NULL;
	m_sSize = 0;
	m_bCSRealloced = false;
}

ZMachO::~ZMachO()
{
    Free();
}

bool ZMachO::Init(const char* szFile)
{
    if (!szFile || !szFile[0]) return false;
    m_bCSRealloced = false;
	m_strFile = szFile;
	return OpenFile(szFile);
}

bool ZMachO::InitV(const char* szPath, ...)
{
	FORMAT_V(szPath, szFile);
	return Init(szFile);
}

bool ZMachO::Free()
{
    bool closed = !m_pBase || CloseFile();
    FreeArchOes();
    return closed;
}

bool ZMachO::NewArchO(uint8_t* pBase, uint32_t uLength)
{
	ZArchO* archo = new ZArchO();
	if (archo->Init(pBase, uLength)) {
		m_arrArchOes.push_back(archo);
		return true;
	}
	delete archo;
	return false;
}

void ZMachO::FreeArchOes()
{
	for (size_t i = 0; i < m_arrArchOes.size(); i++) {
		ZArchO* archo = m_arrArchOes[i];
		delete archo;
	}
	m_pBase = NULL;
	m_sSize = 0;
	m_arrArchOes.clear();
}

bool ZMachO::OpenFile(const char* szPath)
{
    Free();
    m_pBase = static_cast<uint8_t*>(ZFile::MapFile(szPath, 0, 0, &m_sSize, false));
    auto invalid = [this]() { Free(); return false; };
    if (!m_pBase || m_sSize < sizeof(mach_header) || m_sSize > 0x7fffffffU) return invalid();
    auto word = [this](size_t offset, bool big) {
        uint32_t value; memcpy(&value, m_pBase + offset, sizeof(value));
        return big ? LE(value) : value;
    };
    uint32_t magic = word(0, false);
    bool fat64 = magic == 0xbfbafecaU || magic == 0xcafebabfU;
    if (FAT_CIGAM == magic || FAT_MAGIC == magic || fat64) {
        bool big = magic == FAT_CIGAM || magic == 0xbfbafecaU;
        uint32_t count = word(4, big), entrySize = fat64 ? 32 : sizeof(fat_arch);
        if (!count || count > 64 || count > (m_sSize - sizeof(fat_header)) / entrySize) return invalid();
        uint64_t tableEnd = sizeof(fat_header) + count * entrySize;
        vector<pair<uint64_t, uint64_t>> ranges;
        for (uint32_t i = 0; i < count; ++i) {
            size_t entry = sizeof(fat_header) + i * entrySize;
            auto wide = [&word, big](size_t offset) {
                return big ? (uint64_t(word(offset, true)) << 32) | word(offset + 4, true)
                           : (uint64_t(word(offset + 4, false)) << 32) | word(offset, false);
            };
            uint64_t start = fat64 ? wide(entry + 8) : word(entry + 8, big);
            uint64_t size = fat64 ? wide(entry + 16) : word(entry + 12, big);
            uint32_t alignment = word(entry + (fat64 ? 24 : 16), big);
            if (alignment > 30 || start < tableEnd || start > m_sSize || start % 4 ||
                start % (uint64_t(1) << alignment) || size < sizeof(mach_header) || size > m_sSize - start ||
                (fat64 && word(entry + 28, big) != 0)) return invalid();
            for (const auto& range : ranges) if (start < range.second && range.first < start + size) return invalid();
            ranges.emplace_back(start, start + size);
            uint32_t sliceMagic = word(start, false);
            bool sliceBig = sliceMagic == MH_CIGAM || sliceMagic == MH_CIGAM_64;
            if (word(start + 4, sliceBig) != word(entry, big) ||
                word(start + 8, sliceBig) != word(entry + 4, big) || !NewArchO(m_pBase + start, static_cast<uint32_t>(size))) return invalid();
        }
    } else if (MH_MAGIC == magic || MH_CIGAM == magic || MH_MAGIC_64 == magic || MH_CIGAM_64 == magic) {
        if (!NewArchO(m_pBase, static_cast<uint32_t>(m_sSize))) return invalid();
    } else { return invalid(); }
    return !m_arrArchOes.empty();
}

bool ZMachO::CloseFile()
{
	if (NULL == m_pBase || m_sSize <= 0) {
		return false;
	}

	if (!ZFile::UnmapFile((void*)m_pBase, m_sSize)) {
		ZLog::ErrorV(">>> CodeSign write(munmap) failed! Error: %p, %lu, %s\n", m_pBase, m_sSize, strerror(errno));
		return false;
	}
    m_pBase = NULL;
    m_sSize = 0;
	return true;
}

void ZMachO::PrintInfo()
{
	for (size_t i = 0; i < m_arrArchOes.size(); i++) {
		ZArchO* archo = m_arrArchOes[i];
		archo->PrintInfo();
	}
}

bool ZMachO::CheckSignature() const
{
    return !m_arrArchOes.empty() && std::all_of(m_arrArchOes.cbegin(), m_arrArchOes.cend(),
		[](ZArchO const * archo) {
			return archo->IsSigned();
		}
	);
}

bool ZMachO::Sign(ZSignAsset* pSignAsset, bool bForce, string strBundleId, string strInfoSHA1, string strInfoSHA256, const string& strCodeResourcesData)
{
	if (NULL == m_pBase || m_arrArchOes.empty()) {
		return false;
	}

	for (size_t i = 0; i < m_arrArchOes.size(); i++) {
		ZArchO* archo = m_arrArchOes[i];
        string imageBundleId = strBundleId, imageInfoSHA1 = strInfoSHA1, imageInfoSHA256 = strInfoSHA256;
		if (imageBundleId.empty()) {
			jvalue jvInfo;
			jvInfo.read_plist(archo->m_strInfoPlist);
            imageBundleId = jvInfo["CFBundleIdentifier"].as_cstr();
			if (imageBundleId.empty()) {
				imageBundleId = ZUtil::GetBaseName(m_strFile.c_str());
			}
		}

        if (imageInfoSHA1.empty() || imageInfoSHA256.empty()) {
			if (archo->m_strInfoPlist.empty()) {
                imageInfoSHA1.assign(20, 0);
                imageInfoSHA256.assign(32, 0);
			} else {
				ZSHA::SHA(archo->m_strInfoPlist, imageInfoSHA1, imageInfoSHA256);
			}
		}

		if (!archo->Sign(pSignAsset, bForce, imageBundleId, imageInfoSHA1, imageInfoSHA256, strCodeResourcesData)) {
			if (!archo->m_bEnoughSpace && !m_bCSRealloced) {
				m_bCSRealloced = true;
				if (ReallocCodeSignSpace()) {
					return Sign(pSignAsset, bForce, strBundleId, strInfoSHA1, strInfoSHA256, strCodeResourcesData);
				}
			}
			return false;
		}
	}

	return CloseFile();
}

bool ZMachO::ReallocCodeSignSpace()
{
	ZLog::Warn(">>> Realloc CodeSignature space... \n");

	vector<uint32_t> arrMachOesSizes;
	for (size_t i = 0; i < m_arrArchOes.size(); i++) {
		string strNewArchOFile;
		ZUtil::StringFormatV(strNewArchOFile, "%s.archo.%d", m_strFile.c_str(), i);
		uint32_t uNewLength = m_arrArchOes[i]->ReallocCodeSignSpace(strNewArchOFile);
		if (uNewLength <= 0) {
			ZLog::Error(">>> Failed!\n");
			return false;
		}
		arrMachOesSizes.push_back(uNewLength);
	}
	ZLog::Warn(">>> Success!\n");

	if (1 == m_arrArchOes.size()) {
        if (!CloseFile()) return false;
		string strNewArchOFile = m_strFile + ".archo.0";
		if (0 == rename(strNewArchOFile.c_str(), m_strFile.c_str())) {
			return OpenFile(m_strFile.c_str());
		}
	} else { //fat
		uint32_t uAlign = 16384;
		vector<fat_arch> arrArches;
        // Rebuild a canonical FAT32 table from the bounded images, not by
        // reinterpreting a FAT64 (or differently-endian) input table as FAT32.
        fat_header fath;
        fath.magic = BE(static_cast<uint32_t>(FAT_MAGIC));
        fath.nfat_arch = BE(static_cast<uint32_t>(m_arrArchOes.size()));
        for (const ZArchO* image : m_arrArchOes) {
            fat_arch arch = {};
            uint32_t cpu = image->m_pHeader->cputype, subtype = image->m_pHeader->cpusubtype;
            if (image->m_bBigEndian) { cpu = LE(cpu); subtype = LE(subtype); }
            arch.cputype = BE(cpu); arch.cpusubtype = BE(subtype);
            arrArches.push_back(arch);
        }
        if (!CloseFile()) return false;

		uint32_t uFatHeaderSize = sizeof(fat_header) + (uint32_t)arrArches.size() * sizeof(fat_arch);
		uint32_t uPadding1 = (uAlign - uFatHeaderSize % uAlign);
		uint32_t uOffset = uFatHeaderSize + uPadding1;
		for (size_t i = 0; i < arrArches.size(); i++) {
			fat_arch& arch = arrArches[i];
			uint32_t& uMachOSize = arrMachOesSizes[i];

            arch.align = BE(static_cast<uint32_t>(14));
            arch.offset = BE(uOffset);
            arch.size = BE(uMachOSize);
            if (uMachOSize > 0x7fffffffU - uOffset - uAlign) return false;
			uOffset += uMachOSize;
			uOffset = uOffset + (uAlign - uOffset % uAlign);
		}

		string strNewFatMachOFile = m_strFile + ".fato";

		string strFatHeader;
		strFatHeader.append((const char*)&fath, sizeof(fat_header));
		for (size_t i = 0; i < arrArches.size(); i++) {
			fat_arch& arch = arrArches[i];
			strFatHeader.append((const char*)&arch, sizeof(fat_arch));
		}

		string strPadding1;
		strPadding1.append(uPadding1, 0);

        if (!ZFile::WriteFile(strNewFatMachOFile.c_str(), strFatHeader) ||
            !ZFile::AppendFile(strNewFatMachOFile.c_str(), strPadding1)) return false;

		for (size_t i = 0; i < arrArches.size(); i++) {
			size_t sSize = 0;
			string strNewArchOFile = m_strFile + ".archo." + jvalue((int)i).as_string();
			uint8_t* pData = (uint8_t*)ZFile::MapFile(strNewArchOFile.c_str(), 0, 0, &sSize, true);
			if (NULL == pData) {
				ZFile::RemoveFile(strNewFatMachOFile.c_str());
				return false;
			}
			string strPadding;
			strPadding.append((uAlign - sSize % uAlign), 0);

            bool written = ZFile::AppendFile(strNewFatMachOFile.c_str(), (const char*)pData, sSize) &&
                ZFile::AppendFile(strNewFatMachOFile.c_str(), strPadding);
			ZFile::UnmapFile((void*)pData, sSize);
            if (!written) return false;
			ZFile::RemoveFile(strNewArchOFile.c_str());
		}

		if (0 == rename(strNewFatMachOFile.c_str(), m_strFile.c_str())) {
			return OpenFile(m_strFile.c_str());
		}
	}

	return false;
}

bool ZMachO::InjectDylib(bool bWeakInject, const char* szDylibFile)
{
	ZLog::WarnV(">>> InjectDylib: %s %s... \n", szDylibFile, bWeakInject ? "(weak)" : "");

	vector<uint32_t> arrMachOesSizes;
	for (size_t i = 0; i < m_arrArchOes.size(); i++) {
		if (!m_arrArchOes[i]->InjectDylib(bWeakInject, szDylibFile)) {
			ZLog::Error(">>> Failed!\n");
			return false;
		}
	}
	ZLog::Warn(">>> Success!\n");
	return true;
}

bool ZMachO::ChangeDylibPath(const char *oldPath, const char *newPath) {
	ZLog::WarnV(">>> Change DyLib Path: %s -> %s ... \n", oldPath, newPath);
	
	bool pathChanged = true;
	for (size_t i = 0; i < m_arrArchOes.size(); i++) {
		if (!m_arrArchOes[i]->ChangeDylibPath(oldPath, newPath)) {
			ZLog::Error(">>> Failed to change path in one of the architectures!\n");
			pathChanged = false;
		}
	}
	
	if (pathChanged) {
		ZLog::Warn(">>> Successfully changed all dylib paths!\n");
	}
	return pathChanged;
}

std::vector<std::string> ZMachO::ListDylibs() {
	std::vector<std::string> dylibList;
	
	for (size_t i = 0; i < m_arrArchOes.size(); i++) {
		std::vector<std::string> archDylibs = m_arrArchOes[i]->ListDylibs();
		dylibList.insert(dylibList.end(), archDylibs.begin(), archDylibs.end());
	}
	
	ZLog::WarnV(">>> Found %zu dylibs:\n", dylibList.size());
	
	return dylibList;
}

bool ZMachO::RemoveDylib(const std::set<std::string> &dylibNames) {
	ZLog::Warn(">>> Removing specified dylibs...\n");
	
	bool removalSuccessful = true;
	for (size_t i = 0; i < m_arrArchOes.size(); i++) {
		m_arrArchOes[i]->RemoveDylibs(dylibNames);
	}
	
	ZLog::Warn(">>> Finished removing specified dylibs!\n");
	return removalSuccessful;
}
