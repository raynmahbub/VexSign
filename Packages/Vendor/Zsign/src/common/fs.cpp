#include "fs.h"

#if !defined(S_ISREG) && defined(S_IFMT) && defined(S_IFREG)
#define S_ISREG(m) (((m)&S_IFMT) == S_IFREG)
#endif

map<void*, void*> ZFile::s_mapFiles;

bool ZFile::IsRegularFile(const char* path)
{
	struct stat st = { 0 };
	return 0 == stat(path, &st) && S_ISREG(st.st_mode);
}

void* ZFile::MapFile(const char* path, size_t offset, size_t size, size_t* psize, bool ro)
{
	void* base = NULL;
    if (psize) *psize = 0;
    if (!path) return NULL;

#ifdef _WIN32

	HANDLE hFile = ::CreateFileA(path, ro ? GENERIC_READ : (GENERIC_READ | GENERIC_WRITE), ro ? FILE_SHARE_READ : (FILE_SHARE_READ | FILE_SHARE_WRITE), NULL, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
	if (INVALID_HANDLE_VALUE != hFile) {
		if (size <= 0) {
			size = ::GetFileSize(hFile, NULL);
		}

		if (NULL != psize) {
			*psize = size;
		}

		HANDLE hMap = ::CreateFileMapping(hFile, NULL, ro ? PAGE_READONLY : PAGE_READWRITE, 0, (DWORD)size, NULL);
		if (NULL != hMap) {
			base = ::MapViewOfFile(hMap, ro ? FILE_MAP_READ : FILE_MAP_ALL_ACCESS, 0, 0, size);
			if (NULL != base) {
				s_mapFiles[base] = hMap;
			} else {
				::CloseHandle(hMap);
			}
		}
		::CloseHandle(hFile);
	}

#else

    // Mapping is an inspection/mutation primitive, not a permission repair.
    // fd 0 is valid; never chmod or create a file because opening it failed.
    int flags = ro ? O_RDONLY : O_RDWR;
#ifdef O_NOFOLLOW
    flags |= O_NOFOLLOW;
#endif
#ifdef O_CLOEXEC
    flags |= O_CLOEXEC;
#endif
    int fd = open(path, flags);
    if (fd < 0) return NULL;
    struct stat st = { 0 };
    if (fstat(fd, &st) == 0 && S_ISREG(st.st_mode) && st.st_size > 0 &&
        static_cast<uint64_t>(offset) < static_cast<uint64_t>(st.st_size)) {
        const uint64_t available = static_cast<uint64_t>(st.st_size) - offset;
        if (size == 0 && available <= SIZE_MAX) size = static_cast<size_t>(available);
        if (size > 0 && size <= available) {
            base = mmap(NULL, size, ro ? PROT_READ : PROT_READ | PROT_WRITE, MAP_SHARED, fd, offset);
            if (base == MAP_FAILED) base = NULL;
            if (base && psize) *psize = size;
        }
    }
    close(fd);

#endif

	return base;
}

bool ZFile::UnmapFile(void* base, size_t size)
{
#ifdef _WIN32
	auto it = s_mapFiles.find(base);
	if (it != s_mapFiles.end()) {
		::UnmapViewOfFile(base);
		::CloseHandle(it->second);
		s_mapFiles.erase(it);
		return true;
	}
	return false;
#else
	return (0 == munmap(base, size));
#endif
}

bool ZFile::WriteFile(const char* szFile, const char* szData, size_t sLen)
{
	if (NULL == szFile || (sLen > 0 && szData == NULL)) {
		return false;
	}

	FILE* fp = NULL;
	_fopen64(fp, szFile, "wb");
	if (NULL != fp) {
		size_t written = 0;
		size_t to_write = sLen;
		if (NULL != szData) {
			while (written < to_write) {
				size_t ret = fwrite(szData + written, 1, to_write - written, fp);
				if (ret <= 0) {
					break;
				}
				written += ret;
			}
		}
        const bool complete = written == to_write && ferror(fp) == 0;
        const int closed = fclose(fp); // Includes errors from a delayed stdio flush.
        return complete && closed == 0;
	} else {
		ZLog::ErrorV("WriteFile: Failed in fopen! %s, %s\n", szFile, strerror(errno));
	}
	return false;
}

bool ZFile::WriteFile(const char* szFile, const string& strData)
{
	return WriteFile(szFile, strData.data(), strData.size());
}

bool ZFile::WriteFileV(string& strData, const char* szPath, ...)
{
	FORMAT_V(szPath, szRealPath);
	return WriteFile(szRealPath, strData);
}

bool ZFile::WriteFileV(const char* szData, size_t sLen, const char* szPath, ...)
{
	FORMAT_V(szPath, szRealPath);
	return WriteFile(szRealPath, szData, sLen);
}

bool ZFile::ReadFile(const char* szFile, string& strData)
{
    strData.clear();
    if (!szFile) return false;
    FILE* fp = NULL;
    _fopen64(fp, szFile, "rb");
    if (!fp) return false;
#ifndef _WIN32
    struct stat st = { 0 };
    if (fstat(fileno(fp), &st) != 0 || !S_ISREG(st.st_mode)) { fclose(fp); return false; }
#endif
    bool complete = false;
    if (_fseeki64(fp, 0, SEEK_END) == 0) {
        const int64_t length = _ftelli64(fp);
        if (length >= 0 && static_cast<uint64_t>(length) <= strData.max_size() && _fseeki64(fp, 0, SEEK_SET) == 0) {
            try {
                strData.resize(static_cast<size_t>(length));
                size_t read = 0;
                while (read < strData.size()) {
                    const size_t count = fread(&strData[read], 1, strData.size() - read, fp);
                    if (count == 0) break;
                    read += count;
                }
                // Resizing a buffer is not proof that all bytes were read.
                complete = read == strData.size() && ferror(fp) == 0 && fgetc(fp) == EOF && ferror(fp) == 0;
            } catch (const std::exception&) { complete = false; }
        }
    }
    const int closed = fclose(fp);
    if (!complete || closed != 0) { strData.clear(); return false; }
    return true;
}

bool ZFile::ReadFileV(string& strData, const char* szPath, ...)
{
	FORMAT_V(szPath, szRealPath);
	return ZFile::ReadFile(szRealPath, strData);
}

bool ZFile::AppendFile(const char* szFile, const char* szData, size_t sLen)
{
    if (!szFile || (sLen > 0 && !szData)) return false;
    FILE* fp = NULL;
    _fopen64(fp, szFile, "ab+");
    if (!fp) {
        ZLog::ErrorV("AppendFile: Failed in fopen! %s, %s\n", szFile, strerror(errno));
        return false;
    }
    size_t written = 0;
    while (written < sLen) {
        const size_t count = fwrite(szData + written, 1, sLen - written, fp);
        if (count == 0) break;
        written += count;
    }
    const bool complete = written == sLen && ferror(fp) == 0;
    const int closed = fclose(fp);
    return complete && closed == 0;
}

bool ZFile::AppendFile(const char* szFile, const string& strData)
{
	return AppendFile(szFile, strData.data(), strData.size());
}

bool ZFile::IsFolder(const char* szFolder)
{
#ifdef _WIN32
	return ::PathIsDirectoryA(szFolder);
#else
    struct stat st = { 0 };
    return szFolder && stat(szFolder, &st) == 0 && S_ISDIR(st.st_mode);
#endif
}

bool ZFile::IsFolderV(const char* szPath, ...)
{
	FORMAT_V(szPath, szFolder);
	return IsFolder(szFolder);
}

bool ZFile::CreateFolder(const char* szFolder)
{
	string strPath = GetFullPath(szFolder);
	if (!IsFolder(strPath.c_str())) {
#ifdef _WIN32
		int32_t nRet = ::SHCreateDirectoryExA(NULL, strPath.c_str(), NULL);
		if (ERROR_SUCCESS != nRet && ERROR_ALREADY_EXISTS != nRet) {
			return false;
		}
#else
		size_t pos = 0;
		pos = strPath.find('/', pos);
		while (string::npos != pos) {
			string strFolder = strPath.substr(0, pos++);
			if (!strFolder.empty()) {
				if (0 != mkdir(strFolder.c_str(), 0755)) {
					if (EEXIST != errno) {
						return false;
					}
				}
			}
			pos = strPath.find('/', pos);
		}
		if (0 != mkdir(strPath.c_str(), 0755)) {
			if (EEXIST != errno) {
				return false;
			}
		}
		return true;
#endif
	}
	return true;
}

bool ZFile::CreateFolderV(const char* szPath, ...)
{
	FORMAT_V(szPath, szFolder);
	return CreateFolder(szFolder);
}

int ZFile::RemoveFolderCallBack(const char* fpath, const struct stat* sb, int typeflag, struct FTW* ftwbuf)
{
	int ret = remove(fpath);
	if (ret) {
		perror(fpath);
	}
	return ret;
}

bool ZFile::RemoveFolder(const char* szFolder)
{
	if (!IsFolder(szFolder)) {
		RemoveFile(szFolder);
		return true;
	}
#ifdef _WIN32
	string strFolder = szFolder;
	strFolder.push_back('\0');

	SHFILEOPSTRUCTA shfs;
	memset(&shfs, 0, sizeof(shfs));
	shfs.wFunc = FO_DELETE;
	shfs.pFrom = strFolder.c_str();
	shfs.fFlags = FOF_NOCONFIRMATION;
	shfs.fFlags |= (FOF_SILENT | FOF_NOERRORUI);
	return (0 == ::SHFileOperationA(&shfs));
#else
	return 0 == nftw(szFolder, RemoveFolderCallBack, 64, FTW_DEPTH | FTW_PHYS);
#endif
}

bool ZFile::RemoveFolderV(const char* szPath, ...)
{
	FORMAT_V(szPath, szFolder);
	return RemoveFolder(szFolder);
}

bool ZFile::RemoveFile(const char* szFile)
{
	return (0 == remove(szFile));
}

bool ZFile::RemoveFileV(const char* szPath, ...)
{
	FORMAT_V(szPath, szFile);
	return RemoveFile(szFile);
}

bool ZFile::IsFileExists(const char* szFile)
{
	if (NULL == szFile) {
		return false;
	}

#ifdef _WIN32
	return ::PathFileExistsA(szFile);
#else
	return (0 == access(szFile, F_OK));
#endif
}

bool ZFile::IsFileExistsV(const char* szPath, ...)
{
	FORMAT_V(szPath, szFile);
	return IsFileExists(szFile);
}

bool ZFile::IsZipFile(const char* szFile)
{
	if (NULL != szFile && !IsFolder(szFile)) {
		FILE* fp = NULL;
		_fopen64(fp, szFile, "rb");
		if (NULL != fp) {
			uint8_t buf[2] = { 0 };
			fread(buf, 1, 2, fp);
			fclose(fp);
			return (0 == memcmp("PK", buf, 2));
		}
	}
	return false;
}

bool ZFile::CopyFile(const char* szSrcFile, const char* szDestFile)
{
#ifdef _WIN32
	return ::CopyFileA(szSrcFile, szDestFile, FALSE) ? true : false;
#else 

    if (!szSrcFile || !szDestFile) return false;
    int readFlags = O_RDONLY, writeFlags = O_CREAT | O_WRONLY;
#ifdef O_NOFOLLOW
    readFlags |= O_NOFOLLOW; writeFlags |= O_NOFOLLOW;
#endif
#ifdef O_CLOEXEC
    readFlags |= O_CLOEXEC; writeFlags |= O_CLOEXEC;
#endif
    const int source = open(szSrcFile, readFlags);
    if (source < 0) return false;
    struct stat from = { 0 }, to = { 0 };
    if (fstat(source, &from) != 0 || !S_ISREG(from.st_mode)) { close(source); return false; }
    // Check identity before truncation: copying a file onto itself must not
    // erase it, including when two paths are hard links to the same inode.
    const int target = open(szDestFile, writeFlags, 0644);
    if (target < 0) { close(source); return false; }
    bool complete = fstat(target, &to) == 0 && S_ISREG(to.st_mode) &&
        !(from.st_dev == to.st_dev && from.st_ino == to.st_ino) && ftruncate(target, 0) == 0;
    char buffer[64 * 1024];
    while (complete) {
        ssize_t count;
        do { count = read(source, buffer, sizeof(buffer)); } while (count < 0 && errno == EINTR);
        if (count < 0) { complete = false; break; }
        if (count == 0) break;
        ssize_t written = 0;
        while (written < count) {
            ssize_t next;
            do { next = write(target, buffer + written, count - written); } while (next < 0 && errno == EINTR);
            if (next <= 0) { complete = false; break; }
            written += next;
        }
    }
    const int targetClosed = close(target), sourceClosed = close(source);
    return complete && targetClosed == 0 && sourceClosed == 0;

#endif
}

bool ZFile::CopyFileV(const char* szSrcFile, const char* szDestPath, ...)
{
	FORMAT_V(szDestPath, szDestFile);
	return CopyFile(szSrcFile, szDestFile);
}

string ZFile::GetFullPath(const char* szPath)
{
	string strPath = szPath;
	if (!strPath.empty()) {
#ifdef _WIN32
		char path[PATH_MAX] = { 0 };
		if (NULL != _fullpath(path, szPath, PATH_MAX)) {
			strPath = path;
		}
		ZUtil::StringReplace(strPath, "/", "\\");
#else
		char path[PATH_MAX] = { 0 };
		if (NULL != realpath(szPath, path)) {
			strPath = path;
		}
		ZUtil::StringReplace(strPath, "//", "/");
#endif
	}
	return strPath;
}

string ZFile::GetRealPathV(const char* szPath, ...)
{
	FORMAT_V(szPath, szRealPath);
	return GetFullPath(szRealPath);
}

int64_t ZFile::GetFileSize(FILE* fp)
{
	if (NULL != fp) {
		_fseeki64(fp, 0, SEEK_END);
		int64_t size = _ftelli64(fp);
		_fseeki64(fp, 0, SEEK_SET);
		return (size > 0 ? size : 0);
	}
	return 0;
}

int64_t ZFile::GetFileSize(const char* szPath)
{
	int64_t size = 0;
	FILE* fp = NULL;
	_fopen64(fp, szPath, "rb");
	if (NULL != fp) {
		size = GetFileSize(fp);
		fclose(fp);
	}
	return size;
}

int64_t ZFile::GetFileSizeV(const char* szPath, ...)
{
	FORMAT_V(szPath, szFile);
	return GetFileSize(szFile);
}

string ZFile::GetFileSizeString(const char* szFile)
{
	return  ZUtil::FormatSize(GetFileSize(szFile), 1024);
}

bool ZFile::IsPathSuffix(const string& strPath, const char* suffix)
{
	size_t nPos = strPath.rfind(suffix);
	if (string::npos != nPos) {
		if (nPos == (strPath.size() - strlen(suffix))) {
			return true;
		}
	}
	return false;
}

const char* ZFile::GetTempFolder()
{
	static once_flag s_flag;
	static string s_strTempFolder;
	if (s_strTempFolder.empty()) {
		call_once(s_flag, [&]() {
#ifdef _WIN32
			char szTempPath[PATH_MAX] = { 0 };
			if (0 != ::GetTempPathA(PATH_MAX, szTempPath)) {
				s_strTempFolder = szTempPath;
			} else {
				s_strTempFolder = GetFullPath("./");
			}
			if (!s_strTempFolder.empty() && s_strTempFolder.back() == '\\') {
				s_strTempFolder.pop_back();
			}
#else
			s_strTempFolder = "/tmp";
#endif
		});
	}
	return s_strTempFolder.c_str();
}

bool ZFile::EnumFolder(const char* szFolder, bool bRecursive, enum_folder_callback filter, enum_folder_callback callback)
{
	string strFolder = szFolder;
	if (strFolder.empty() || NULL == callback) {
		return false;
	}

#ifdef _WIN32
	string strFromFolder = strFolder + "\\*";
	WIN32_FIND_DATAA fd = { 0 };
	HANDLE hFind = ::FindFirstFileA(strFromFolder.c_str(), &fd);
	if (INVALID_HANDLE_VALUE == hFind) {
		return false;
	}

	while (::FindNextFileA(hFind, &fd)) {
		if (0 == strcmp(fd.cFileName, ".") || 0 == strcmp(fd.cFileName, "..")) {
			continue;
		}

		string strName = fd.cFileName;
		string strPath = strFolder + "\\" + strName;
		bool bFolder = (fd.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) ? true : false;

		if (NULL != filter) {
			if (filter(bFolder, strPath)) {
				continue;
			}
		}

		if (callback(bFolder, strPath)) {
			break;
		}

		if (bFolder && bRecursive) {
			EnumFolder(strPath.c_str(), bRecursive, filter, callback);
		}
	}
	::FindClose(hFind);

#else

	DIR* dir = opendir(szFolder);
	if (NULL == dir) {
		return false;
	}
	
	dirent* ptr = readdir(dir);
	while (NULL != ptr) {
		if (0 == strcmp(ptr->d_name, ".") || 0 == strcmp(ptr->d_name, "..")) {
			ptr = readdir(dir);
			continue;
		}

		string strPath = strFolder + "/" + ptr->d_name;

		bool bFolder = false;
		if (DT_DIR == ptr->d_type) {
			bFolder = true;
		} else if (DT_UNKNOWN == ptr->d_type) {
			struct stat st = { 0 };
			stat(strPath.c_str(), &st);
			if (S_ISDIR(st.st_mode)) {
				bFolder = true;
			}
		}

		if (NULL != filter) {
			if (filter(bFolder, strPath)) {
				ptr = readdir(dir);
				continue;
			}
		}

		if (callback(bFolder, strPath)) {
			break;
		}

		if (bFolder && bRecursive) {
			EnumFolder(strPath.c_str(), bRecursive, filter, callback);
		}

		ptr = readdir(dir);
	}
	closedir(dir);

#endif

	return true;
}

bool ZFile::PathRemoveFileSpec(string& path)
{
	size_t pos = path.find_last_of("/\\");
	if (pos != std::string::npos) {
		path = path.substr(0, pos);
		return true;
	}
	return false;
}
