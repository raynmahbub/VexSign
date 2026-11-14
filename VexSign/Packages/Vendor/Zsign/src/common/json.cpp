#include "json.h"
#include "base64.h"
#include <time.h>
#include <math.h>
#include <assert.h>
#include <stdarg.h>
#include <limits>
#include <cmath>
#include <sstream>
#include <locale>
#include <algorithm>
using namespace std;

#ifdef _WIN32

#define _fopen64(fp, path, mode)	{ fopen_s(&fp, path, mode); }
#define PRId64						"lld"

#else

#ifdef __APPLE__
#define PRId64						"lld"
#else
#define PRId64						"ld"
#endif

#define _fseeki64					fseeko
#define _ftelli64					ftello
#define _atoi64(val)				strtoll(val, NULL, 10)
#define sscanf_s 					sscanf
#define _fopen64(fp, path, mode)	{fp = fopen(path, mode); }

#endif


const jvalue jvalue::null;
const string jvalue::null_data;

jvalue::jvalue(jtype type)
{
	m_type = type;
	m_value.v_double = 0;
}

jvalue::jvalue(int val)
{
	m_type = E_INT;
	m_value.v_int64 = val;
}

jvalue::jvalue(int64_t val)
{
	m_type = E_INT;
	m_value.v_int64 = val;
}

jvalue::jvalue(bool val)
{
	m_type = E_BOOL;
	m_value.v_bool = val;
}

jvalue::jvalue(double val)
{
	m_type = E_FLOAT;
	m_value.v_double = val;
}

jvalue::jvalue(const char* val)
{
	m_type = E_STRING;
	m_value.p_string = _new_string(val);
}

jvalue::jvalue(const string& val)
{
	m_type = E_STRING;
	m_value.p_string = _new_string(val.c_str());
}

jvalue::jvalue(const jvalue& other)
{
	_copy_value(other);
}

jvalue::jvalue(const char* val, size_t len)
{
	m_type = E_DATA;
	m_value.p_data = new string();
	m_value.p_data->append(val, len);
}

jvalue::~jvalue()
{
	_free();
}

void jvalue::clear()
{
	_free();
}

bool jvalue::is_int() const
{
	return (E_INT == m_type);
}

bool jvalue::is_null() const
{
	return (E_NULL == m_type);
}

bool jvalue::is_bool() const
{
	return (E_BOOL == m_type);
}

bool jvalue::is_double() const
{
	return (E_FLOAT == m_type);
}

bool jvalue::is_string() const
{
	return (E_STRING == m_type);
}

bool jvalue::is_array() const
{
	return (E_ARRAY == m_type);
}

bool jvalue::is_object() const
{
	return (E_OBJECT == m_type);
}

bool jvalue::is_empty() const
{
	switch (m_type) {
	case E_NULL:
		return true;
		break;
	case E_INT:
		return (0 == m_value.v_int64);
		break;
	case E_BOOL:
		return (false == m_value.v_bool);
		break;
	case E_FLOAT:
		return (0 == m_value.v_double);
		break;
	case E_ARRAY:
	case E_OBJECT:
		return (0 == size());
		break;
	case E_STRING:
		return (0 == strlen(as_cstr()));
	case E_DATE:
		return (0 == m_value.v_date);
		break;
	case E_DATA:
		return (NULL == m_value.p_data) ? true : m_value.p_data->empty();
		break;
	}
	return true;
}

jvalue::operator const char* () const
{
	return as_cstr();
}

jvalue::operator int() const
{
	return as_int();
}

jvalue::operator int64_t() const
{
	return as_int64();
}

jvalue::operator double() const
{
	return as_double();
}

jvalue::operator string() const
{
	return as_cstr();
}

jvalue::operator bool() const
{
	return as_bool();
}

char* jvalue::_new_string(const char* cstr)
{
	char* str = NULL;
	if (NULL != cstr) {
		size_t len = (strlen(cstr) + 1) * sizeof(char);
		str = (char*)::malloc(len);
		if (NULL != str) {
			::memcpy(str, cstr, len);
		}
	}
	return str;
}

void jvalue::_copy_value(const jvalue& src)
{
	m_type = src.m_type;
	switch (m_type) {
	case E_ARRAY:
		m_value.p_array = (NULL == src.m_value.p_array) ? NULL : new array(*(src.m_value.p_array));
		break;
	case E_OBJECT:
	{
		m_value.p_object = (NULL == src.m_value.p_object) ? NULL : new object();
		if (NULL != m_value.p_object) {
			*m_value.p_object = *src.m_value.p_object;
		}
	}
	break;
	case E_STRING:
		m_value.p_string = (NULL == src.m_value.p_string) ? NULL : _new_string(src.m_value.p_string);
		break;
	case E_DATA:
	{
		if (NULL != src.m_value.p_data) {
			m_value.p_data = new string();
			*m_value.p_data = *src.m_value.p_data;
		} else {
			m_value.p_data = NULL;
		}
	}
	break;
	default:
		m_value = src.m_value;
		break;
	}
}

void jvalue::_free()
{
	switch (m_type) {
	case E_INT:
	{
		m_value.v_int64 = 0;
	}
	break;
	case E_BOOL:
	{
		m_value.v_bool = false;
	}
	break;
	case E_FLOAT:
	{
		m_value.v_double = 0.0;
	}
	break;
	case E_STRING:
	{
		if (NULL != m_value.p_string) {
			::free(m_value.p_string);
			m_value.p_string = NULL;
		}
	}
	break;
	case E_ARRAY:
	{
		if (NULL != m_value.p_array) {
			delete m_value.p_array;
			m_value.p_array = NULL;
		}
	}
	break;
	case E_OBJECT:
	{
		if (NULL != m_value.p_object) {
			delete m_value.p_object;
			m_value.p_object = NULL;
		}

	}
	break;
	case E_DATE:
	{
		m_value.v_date = 0;
	}
	break;
	case E_DATA:
	{
		if (NULL != m_value.p_data) {
			delete m_value.p_data;
			m_value.p_data = NULL;
		}
	}
	break;
	default:
		break;
	}
	m_type = E_NULL;
}

jvalue::jtype jvalue::type() const
{
	return m_type;
}

int jvalue::as_int() const
{
	return (int)as_int64();
}

int64_t	jvalue::as_int64() const
{
	switch (m_type) {
	case E_INT:
		return m_value.v_int64;
		break;
	case E_BOOL:
		return m_value.v_bool ? 1 : 0;
		break;
	case E_FLOAT:
		return int(m_value.v_double);
		break;
	case E_STRING:
		return _atoi64(as_cstr());
		break;
	default:
		break;
	}
	return 0;
}

double jvalue::as_double() const
{
	switch (m_type) {
	case E_INT:
		return double(m_value.v_int64);
		break;
	case E_BOOL:
		return m_value.v_bool ? 1.0 : 0.0;
		break;
	case E_FLOAT:
		return m_value.v_double;
		break;
	case E_STRING:
		return atof(as_cstr());
		break;
	default:
		break;
	}
	return 0.0;
}

bool jvalue::as_bool() const
{
	switch (m_type) {
	case E_BOOL:
		return m_value.v_bool;
		break;
	case E_INT:
		return (0 != m_value.v_int64);
		break;
	case E_FLOAT:
		return (0.0 != m_value.v_double);
		break;
	case E_ARRAY:
		return (NULL == m_value.p_array) ? false : (m_value.p_array->size() > 0);
		break;
	case E_OBJECT:
		return (NULL == m_value.p_object) ? false : (m_value.p_object->size() > 0);
		break;
	case E_STRING:
		return (NULL == m_value.p_string) ? false : (strlen(m_value.p_string) > 0);
		break;
	case E_DATE:
		return (m_value.v_date > 0);
		break;
	case E_DATA:
		return (NULL == m_value.p_data) ? false : (m_value.p_data->size() > 0);
		break;
	default:
		break;
	}
	return false;
}

string jvalue::as_string() const
{
	switch (m_type) {
	case E_BOOL:
		return m_value.v_bool ? "true" : "false";
		break;
	case E_INT:
	{
		char buf[32];
		::snprintf(buf, 32, "%" PRId64, m_value.v_int64);
		return buf;
	}
	break;
	case E_FLOAT:
	{
		char buf[256];
		::snprintf(buf, 256, "%lf", m_value.v_double);
		return buf;
	}
	break;
	case E_ARRAY:
		return "array";
		break;
	case E_OBJECT:
		return "object";
		break;
	case E_STRING:
		return (NULL == m_value.p_string) ? "" : m_value.p_string;
		break;
	case E_DATE:
	{
		char buf[256];
#ifdef _WIN32
		::snprintf(buf, 256, "%lld", m_value.v_date);
#else
		::snprintf(buf, 256, "%ld", m_value.v_date);
#endif
		return buf;
	}
	break;
	case E_DATA:
		return as_data();
		break;
	default:
		break;
	}
	return "";
}

const char* jvalue::as_cstr() const
{
	if (E_STRING == m_type && NULL != m_value.p_string) {
		return m_value.p_string;
	}
	return "";
}

size_t jvalue::size() const
{
	switch (m_type) {
	case E_ARRAY:
		return (NULL == m_value.p_array) ? 0 : m_value.p_array->size();
		break;
	case E_OBJECT:
		return (NULL == m_value.p_object) ? 0 : m_value.p_object->size();
		break;
	case E_DATA:
		return (NULL == m_value.p_data) ? 0 : m_value.p_data->size();
		break;
	default:
		break;
	}
	return 0;
}

jvalue& jvalue::operator=(const jvalue& other)
{
	if (this != &other) {
		_free();
		_copy_value(other);
	}
	return (*this);
}

jvalue& jvalue::operator[](int index)
{
	return (*this)[(size_t)(index < 0 ? 0 : index)];
}

const jvalue& jvalue::operator[](int index) const
{
	return (*this)[(size_t)(index < 0 ? 0 : index)];
}

jvalue& jvalue::operator[](int64_t index)
{
	return (*this)[(size_t)(index < 0 ? 0 : index)];
}

const jvalue& jvalue::operator[](int64_t index) const
{
	return (*this)[(size_t)(index < 0 ? 0 : index)];
}

jvalue& jvalue::operator[](size_t index)
{
	if (E_ARRAY != m_type || NULL == m_value.p_array) {
		_free();
		m_type = E_ARRAY;
		m_value.p_array = new array();
	}

	size_t sum = m_value.p_array->size();
	if (sum <= index) {
		size_t fill = index - sum;
		for (size_t i = 0; i <= fill; i++) {
			m_value.p_array->push_back(null);
		}
	}

	return m_value.p_array->at(index);
}

const jvalue& jvalue::operator[](size_t index) const
{
	if (E_ARRAY == m_type && NULL != m_value.p_array) {
		if (index < m_value.p_array->size()) {
			return m_value.p_array->at(index);
		}
	}
	return null;
}

jvalue& jvalue::operator[](const string& key)
{
	return (*this)[key.c_str()];
}

const jvalue& jvalue::operator[](const string& key) const
{
	return (*this)[key.c_str()];
}

jvalue& jvalue::operator[](const char* key)
{
	if (E_OBJECT != m_type || NULL == m_value.p_object) {
		_free();
		m_type = E_OBJECT;
		m_value.p_object = new object();
	} else {
		auto it = m_value.p_object->find(key);
		if (it != m_value.p_object->end()) {
			return it->second;
		}
	}
	auto it = m_value.p_object->insert(m_value.p_object->end(), make_pair(key, null));
	return it->second;
}

const jvalue& jvalue::operator[](const char* key) const
{
	if (E_OBJECT == m_type && NULL != m_value.p_object) {
		auto it = m_value.p_object->find(key);
		if (it != m_value.p_object->end()) {
			return it->second;
		}
	}
	return null;
}

bool jvalue::has(int index) const
{
	if (index >= 0) {
		return has((size_t)index);
	}
	return false;
}

bool jvalue::has(size_t index) const
{
	if (E_ARRAY == m_type && NULL != m_value.p_array) {
		if (index < size()) {
			return true;
		}
	}
	return false;
}

bool jvalue::has(const char* key) const
{
	if (E_OBJECT == m_type && NULL != m_value.p_object) {
		if (m_value.p_object->end() != m_value.p_object->find(key)) {
			return true;
		}
	}
	return false;
}

bool jvalue::has(const string& key) const
{
	return has(key.c_str());
}

const jvalue& jvalue::at(int index) const
{
	return (*this)[(size_t)(index < 0 ? 0 : index)];
}

const jvalue& jvalue::at(size_t index) const
{
	return (*this)[index];
}

const jvalue& jvalue::at(const char* key) const
{
	return (*this)[key];
}

bool jvalue::erase(int index)
{
	if (index >= 0) {
		return erase((size_t)index);
	}
	return false;
}

bool jvalue::erase(size_t index)
{
	if (E_ARRAY == m_type && NULL != m_value.p_array) {
		if (index < m_value.p_array->size()) {
			m_value.p_array->erase(m_value.p_array->begin() + index);
			return true;
		}
	}
	return false;
}

bool jvalue::erase(const char* key)
{
	if (E_OBJECT == m_type && NULL != m_value.p_object) {
		if (m_value.p_object->end() != m_value.p_object->find(key)) {
			m_value.p_object->erase(key);
			return !has(key);
		}
	}
	return false;
}

bool jvalue::get_keys(vector<string>& keys) const
{
	if (E_OBJECT == m_type && NULL != m_value.p_object) {
		return _map_keys(keys);
	}
	return false;
}

bool jvalue::_map_keys(vector<string>& keys) const
{
	if (E_OBJECT == m_type && NULL != m_value.p_object) {
		keys.reserve(m_value.p_object->size());
		auto itbeg = m_value.p_object->begin();
		auto itend = m_value.p_object->end();
		for (; itbeg != itend; itbeg++) {
			keys.push_back((itbeg->first).c_str());
		}
		return true;
	}
	return false;
}

int jvalue::index(const char* elem) const
{
	if (E_ARRAY == m_type && NULL != m_value.p_array) {
		for (size_t i = 0; i < m_value.p_array->size(); i++) {
			if (elem == (*m_value.p_array)[i].as_string()) {
				return (int)i;
			}
		}
	}
	return -1;
}

string jvalue::write() const
{
	string strdoc;
	return write(strdoc);
}

const char* jvalue::write(string& strdoc) const
{
	strdoc.clear();
	jwriter::write((*this), strdoc);
	return strdoc.c_str();
}

bool jvalue::read(const string& strdoc, string* pstrerr)
{
	return read(strdoc.c_str(), pstrerr);
}

bool jvalue::read(const char* pdoc, string* pstrerr)
{
	jreader reader;
	bool bret = reader.parse(pdoc, *this);
	if (!bret) {
		if (NULL != pstrerr) {
			reader.error(*pstrerr);
		}
	}
	return bret;
}

jvalue& jvalue::front()
{
	if (E_ARRAY == m_type) {
		if (size() > 0) {
			return *(m_value.p_array->begin());
		}
	} else if (E_OBJECT == m_type) {
		if (size() > 0) {
			return m_value.p_object->begin()->second;
		}
	}
	return (*this);
}

jvalue& jvalue::back()
{
	if (E_ARRAY == m_type) {
		if (size() > 0) {
			return *(m_value.p_array->rbegin());
		}
	} else if (E_OBJECT == m_type) {
		if (size() > 0) {
			return prev(m_value.p_object->end())->second;
		}
	}
	return (*this);
}

bool jvalue::append(jvalue& jv)
{
	if ((E_OBJECT == m_type || E_NULL == m_type) && E_OBJECT == jv.type()) {
		vector<string> keys;
		jv.get_keys(keys);
		for (size_t i = 0; i < keys.size(); i++) {
			(*this)[keys[i]] = jv[keys[i]];
		}
		return true;
	} else if ((E_ARRAY == m_type || E_NULL == m_type) && E_ARRAY == jv.type()) {
		size_t count = this->size();
		for (size_t i = 0; i < jv.size(); i++) {
			(*this)[count] = jv[i];
			count++;
		}
		return true;
	}

	return false;
}

bool jvalue::push_back(int val)
{
	return push_back(jvalue(val));
}

bool jvalue::push_back(bool val)
{
	return push_back(jvalue(val));
}

bool jvalue::push_back(double val)
{
	return push_back(jvalue(val));
}

bool jvalue::push_back(int64_t val)
{
	return push_back(jvalue(val));
}

bool jvalue::push_back(const char* val)
{
	return push_back(jvalue(val));
}

bool jvalue::push_back(const string& val)
{
	return push_back(jvalue(val));
}

bool jvalue::push_back(const jvalue& jval)
{
	if (E_ARRAY == m_type || E_NULL == m_type) {
		(*this)[size()] = jval;
		return true;
	}
	return false;
}

bool jvalue::push_back(const char* val, size_t len)
{
	return push_back(jvalue(val, len));
}

string jvalue::style_write() const
{
	string strdoc;
	return style_write(strdoc);
}

const char* jvalue::style_write(string& strdoc) const
{
	strdoc.clear();
	jwriter jw;
	strdoc = jw.style_write(*this);
	return strdoc.c_str();
}

void jvalue::assign_date(time_t val)
{
	_free();
	m_type = E_DATE;
	m_value.v_date = val;
}

void jvalue::assign_data(const uint8_t* data, size_t size)
{
	_free();
	m_type = E_DATA;
	m_value.p_data = new string();
	m_value.p_data->append((const char*)data, size);
}

void jvalue::assign_data(const char* base64)
{
	jbase64 b64;
	string output;
	b64.decode(base64, output);
	assign_data(output);
}

void jvalue::assign_data(const string& data)
{
	return assign_data(data.data(), data.size());
}

void jvalue::assign_data(const char* data, size_t size)
{
	return assign_data((const uint8_t*)data, size);
}

void jvalue::assign_date_string(time_t val)
{
	_free();
	m_type = E_STRING;
	m_value.p_string = _new_string(jwriter::d2s(val).c_str());
}

time_t jvalue::as_date() const
{
	switch (m_type) {
	case E_DATE:
		return m_value.v_date;
		break;
	case E_STRING:
	{
		if (is_date_string()) {
			tm ft = { 0 };
			sscanf_s(m_value.p_string + 5, "%04d-%02d-%02dT%02d:%02d:%02dZ", &ft.tm_year, &ft.tm_mon, &ft.tm_mday, &ft.tm_hour, &ft.tm_min, &ft.tm_sec);
			ft.tm_mon -= 1;
			ft.tm_year -= 1900;
			return mktime(&ft);
		}
	}
	break;
	case E_NULL:
	case E_INT:
	case E_FLOAT:
	case E_BOOL:
	case E_ARRAY:
	case E_OBJECT:
	case E_DATA:
		break;
	}
	return 0;
}

string jvalue::as_data() const
{
	switch (m_type) {
	case E_DATA:
		return (NULL == m_value.p_data) ? null_data : *m_value.p_data;
		break;
	case E_STRING:
	{
		string data;
		as_data(data);
		return data;
	}
	break;
	case E_NULL:
	case E_INT:
	case E_FLOAT:
	case E_BOOL:
	case E_ARRAY:
	case E_OBJECT:
	case E_DATE:
		break;
	}
	return null_data;
}

bool jvalue::as_data(string& data) const
{
	switch (m_type) {
	case E_DATA:
	{
		data = (NULL == m_value.p_data) ? null_data : *m_value.p_data;
		return true;
	}
	break;
	case E_STRING:
	{
		if (is_data_string()) {
			jbase64 b64;
			int data_len = 0;
			const char* pdata = b64.decode(m_value.p_string + 5, 0, &data_len);
			data.append(pdata, data_len);
			return true;
		}
	}
	break;
	case E_NULL:
	case E_INT:
	case E_FLOAT:
	case E_BOOL:
	case E_ARRAY:
	case E_OBJECT:
	case E_DATE:
		break;
	}
	return false;
}

bool jvalue::is_data() const
{
	return (E_DATA == m_type);
}

bool jvalue::is_date() const
{
	return (E_DATE == m_type);
}

bool jvalue::is_data_string() const
{
	if (E_STRING == m_type) {
		if (NULL != m_value.p_string) {
			if (strlen(m_value.p_string) >= 5) {
				if (0 == memcmp(m_value.p_string, "data:", 5)) {
					return true;
				}
			}
		}
	}

	return false;
}

bool jvalue::is_date_string() const
{
	if (E_STRING == m_type) {
		if (NULL != m_value.p_string) {
			if (25 == strlen(m_value.p_string)) {
				if (0 == memcmp(m_value.p_string, "date:", 5)) {
					const char* pdate = m_value.p_string + 5;
					if ('T' == pdate[10] && 'Z' == pdate[19]) {
						return true;
					}
				}
			}
		}
	}

	return false;
}

bool jvalue::read_plist(const string& strdoc, string* pstrerr /*= NULL*/, bool* is_binary /*= NULL*/)
{
	return read_plist(strdoc.data(), strdoc.size(), pstrerr, is_binary);
}

bool jvalue::read_plist(const char* pdoc, size_t len /*= 0*/, string* pstrerr /*= NULL*/, bool* is_binary /*= NULL*/)
{
	if (NULL == pdoc) {
		return false;
	}

	if (0 == len) {
		len = strlen(pdoc);
	}

	jpreader reader;
	bool bret = reader.parse(pdoc, len, *this, is_binary);
	if (!bret) {
        clear(); // A caller ignoring failure must not consume a partial tree.
		if (NULL != pstrerr) {
			reader.error(*pstrerr);
		}
	}

	return bret;
}

bool jvalue::_read_data_from_file(const char* path, string& data)
{
	data.clear();
	FILE* fp = NULL;
	_fopen64(fp, path, "rb");
	if (NULL != fp) {
		_fseeki64(fp, 0, SEEK_END);
		int64_t to_read = _ftelli64(fp);
		_fseeki64(fp, 0, SEEK_SET);
		to_read = (to_read > 0 ? to_read : 0);
		data.resize(to_read);
		if (data.capacity() >= (size_t)to_read) {
			int64_t readed = 0;
			while (readed < to_read) {
				size_t ret = fread(&(data[readed]), 1, to_read - readed, fp);
				if (ret <= 0) {
					break;
				}
				readed += ret;
			}
		}
		fclose(fp);
		return (data.size() == to_read);
	}
	return false;
}

bool jvalue::read_from_file(const char* path, ...)
{
	char file[1024] = { 0 };
	va_list args;
	va_start(args, path);
	vsnprintf(file, 1024, path, args);
	va_end(args);

	string data;
	if (_read_data_from_file(file, data)) {
		return read(data);
	}
	return false;
}

bool jvalue::read_plist_from_file(const char* path, ...)
{
	char file[1024] = { 0 };
	va_list args;
	va_start(args, path);
	vsnprintf(file, 1024, path, args);
	va_end(args);

	string data;
	if (_read_data_from_file(file, data)) {
		return read_plist(data);
	}
	return false;
}

bool jvalue::_write_data_to_file(const char* path, string& data)
{
	FILE* fp = NULL;
	_fopen64(fp, path, "wb");
	if (NULL != fp) {
		size_t written = 0;
		size_t to_write = data.size();
		while (written < to_write) {
			size_t ret = fwrite(data.data() + written, 1, to_write - written, fp);
			if (ret <= 0) {
				break;
			}
			written += ret;
		}
		fclose(fp);
		return (written == to_write);
	}
	return false;
}

bool jvalue::write_to_file(const char* path, ...)
{
	char file[1024] = { 0 };
	va_list args;
	va_start(args, path);
	vsnprintf(file, 1024, path, args);
	va_end(args);

	string data;
	write(data);
	return _write_data_to_file(file, data);
}

bool jvalue::write_plist_to_file(const char* path, ...)
{
	char file[1024] = { 0 };
	va_list args;
	va_start(args, path);
	vsnprintf(file, 1024, path, args);
	va_end(args);

	string data;
	write_plist(data);
	return _write_data_to_file(file, data);
}

bool jvalue::write_bplist_to_file(const char* path, ...)
{
	char file[1024] = { 0 };
	va_list args;
	va_start(args, path);
	vsnprintf(file, 1024, path, args);
	va_end(args);

	string data;
	write_bplist(data);
	return _write_data_to_file(file, data);
}

bool jvalue::style_write_to_file(const char* path, ...)
{
	char file[1024] = { 0 };
	va_list args;
	va_start(args, path);
	vsnprintf(file, 1024, path, args);
	va_end(args);

	string data;
	style_write(data);
	return _write_data_to_file(file, data);
}

bool jvalue::style_write_plist_to_file(const char* path, ...)
{
	char file[1024] = { 0 };
	va_list args;
	va_start(args, path);
	vsnprintf(file, 1024, path, args);
	va_end(args);

	string data;
	style_write_plist(data);
	return _write_data_to_file(file, data);
}

string jvalue::write_plist() const
{
	string strdoc;
	return write_plist(strdoc);
}

const char* jvalue::write_plist(string& strdoc) const
{
	strdoc.clear();
	jpwriter pw;
	pw.write((*this), strdoc);
	return strdoc.c_str();
}

string jvalue::style_write_plist() const
{
	string strdoc;
	return style_write_plist(strdoc);
}

const char* jvalue::style_write_plist(string& strdoc) const
{
	strdoc.clear();
	jpwriter pw;
	strdoc = pw.style_write(*this);
	return strdoc.c_str();
}

bool jvalue::write_bplist(string& strdoc) const
{
	strdoc.clear();
	jpwriter pw;
	pw.write_to_binary((*this), strdoc);
	return !strdoc.empty();
}

string jvalue::write_to_html() const
{
	string strdoc;
	jwriter::write_to_html((*this), strdoc);
	return strdoc;
}


// Class Reader
// //////////////////////////////////////////////////////////////////
jreader::jreader()
{
	m_pbegin = NULL;
	m_pend = NULL;
	m_pcursor = NULL;
	m_perror = NULL;
}

bool jreader::parse(const char* pdoc, jvalue& root)
{
	if (NULL != pdoc) {
		m_pbegin = pdoc;
		m_pend = m_pbegin + strlen(pdoc);
		m_pcursor = m_pbegin;
		m_perror = m_pbegin;
		m_strerr = "null";

		root.clear();
		return _read_value(root);
	}
	return false;
}

bool jreader::_read_value(jvalue& jval)
{
	jtoken token;
	_read_token(token);
	switch (token.type) {
	case jtoken::E_JTOKEN_TRUE:
		jval = true;
		break;
	case jtoken::E_JTOKEN_FALSE:
		jval = false;
		break;
	case jtoken::E_JTOKEN_NULL:
		jval = jvalue();
		break;
	case jtoken::E_JTOKEN_NUMBER:
		return _decode_number(token, jval);
		break;
	case jtoken::E_JTOKEN_ARRAY_BEGIN:
		return _read_array(jval);
		break;
	case jtoken::E_JTOKEN_OBJECT_BEGIN:
		return _read_object(jval);
		break;
	case jtoken::E_JTOKEN_STRING:
	{
		string strval;
		bool bok = _decode_string(token, strval);
		if (bok) {
			jval = strval.c_str();
		}
		return bok;
	}
	break;
	default:
		return _add_error("Syntax error: value, object or array expected.", token.pbegin);
		break;
	}
	return true;
}

bool jreader::_read_token(jtoken& token)
{
	_skip_spaces();
	token.pbegin = m_pcursor;
	switch (_get_next_char()) {
	case '{':
		token.type = jtoken::E_JTOKEN_OBJECT_BEGIN;
		break;
	case '}':
		token.type = jtoken::E_JTOKEN_OBJECT_END;
		break;
	case '[':
		token.type = jtoken::E_JTOKEN_ARRAY_BEGIN;
		break;
	case ']':
		token.type = jtoken::E_JTOKEN_ARRAY_END;
		break;
	case ',':
		token.type = jtoken::E_JTOKEN_ARRAY_SEPARATOR;
		break;
	case ':':
		token.type = jtoken::E_JTOKEN_MEMBER_SEPARATOR;
		break;
	case 0:
		token.type = jtoken::E_JTOKEN_END;
		break;
	case '"':
		token.type = _read_string() ? jtoken::E_JTOKEN_STRING : jtoken::E_JTOKEN_ERROR;
		break;
	case '/':
	case '#':
	case ';':
	{
		_skip_comment();
		return _read_token(token);
	}
	break;
	case '0':
	case '1':
	case '2':
	case '3':
	case '4':
	case '5':
	case '6':
	case '7':
	case '8':
	case '9':
	case '-':
	{
		token.type = jtoken::E_JTOKEN_NUMBER;
		_read_number();
	}
	break;
	case 't':
		token.type = _match("rue", 3) ? jtoken::E_JTOKEN_TRUE : jtoken::E_JTOKEN_ERROR;
		break;
	case 'f':
		token.type = _match("alse", 4) ? jtoken::E_JTOKEN_FALSE : jtoken::E_JTOKEN_ERROR;
		break;
	case 'n':
		token.type = _match("ull", 3) ? jtoken::E_JTOKEN_NULL : jtoken::E_JTOKEN_ERROR;
		break;
	default:
		token.type = jtoken::E_JTOKEN_ERROR;
		break;
	}
	token.pend = m_pcursor;
	return true;
}

void jreader::_skip_spaces()
{
	while (m_pcursor != m_pend) {
		char c = *m_pcursor;
		if (c == ' ' || c == '\t' || c == '\r' || c == '\n') {
			m_pcursor++;
		} else {
			break;
		}
	}
}

bool jreader::_match(const char* pattern, int pattern_length)
{
	if (m_pend - m_pcursor < pattern_length) {
		return false;
	}
	int index = pattern_length;
	while (index--) {
		if (m_pcursor[index] != pattern[index]) {
			return false;
		}
	}
	m_pcursor += pattern_length;
	return true;
}

void jreader::_skip_comment()
{
	char c = _get_next_char();
	if (c == '*') {
		while (m_pcursor != m_pend) {
			char c = _get_next_char();
			if (c == '*' && *m_pcursor == '/') {
				break;
			}
		}
	} else if (c == '/') {
		while (m_pcursor != m_pend) {
			char c = _get_next_char();
			if (c == '\r' || c == '\n') {
				break;
			}
		}
	}
}

void jreader::_read_number()
{
	while (m_pcursor != m_pend) {
		char c = *m_pcursor;
		if ((c >= '0' && c <= '9') || (c == '.' || c == 'e' || c == 'E' || c == '+' || c == '-')) {
			++m_pcursor;
		} else {
			break;
		}
	}
}

bool jreader::_read_string()
{
	char c = 0;
	while (m_pcursor != m_pend) {
		c = _get_next_char();
		if ('\\' == c) {
			_get_next_char();
		} else if ('"' == c) {
			break;
		}
	}
	return ('"' == c);
}

bool jreader::_read_object(jvalue& jval)
{
	string name;
	jtoken token_name;
	if (jvalue::E_OBJECT != jval.type()) {
		jval = jvalue(jvalue::E_OBJECT);
	}
	while (_read_token(token_name)) {
		if (jtoken::E_JTOKEN_OBJECT_END == token_name.type) {//empty
			return true;
		}

		if (jtoken::E_JTOKEN_STRING != token_name.type) {
			break;
		}

		if (!_decode_string(token_name, name)) {
			return false;
		}

		jtoken colon;
		_read_token(colon);
		if (jtoken::E_JTOKEN_MEMBER_SEPARATOR != colon.type) {
			return _add_error("missing ':' after object member name", colon.pbegin);
		}

		if (!_read_value(jval[name.c_str()])) {// error already set
			return false;
		}

		jtoken comma;
		_read_token(comma);
		if (jtoken::E_JTOKEN_OBJECT_END == comma.type) {
			return true;
		}

		if (jtoken::E_JTOKEN_ARRAY_SEPARATOR != comma.type) {
			return _add_error("missing ',' or '}' in object declaration", comma.pbegin);
		}
	}
	return _add_error("missing '}' or object member name", token_name.pbegin);
}


bool jreader::_read_array(jvalue& jval)
{
	jval = jvalue(jvalue::E_ARRAY);
	_skip_spaces();
	if (']' == *m_pcursor) // empty array
	{
		jtoken endArray;
		_read_token(endArray);
		return true;
	}

	size_t index = 0;
	while (true) {
		if (!_read_value(jval[index++])) {//error already set
			return false;
		}

		jtoken token;
		_read_token(token);
		if (jtoken::E_JTOKEN_ARRAY_END == token.type) {
			break;
		}
		if (jtoken::E_JTOKEN_ARRAY_SEPARATOR != token.type) {
			return _add_error("missing ',' or ']' in array declaration", token.pbegin);
		}
	}
	return true;
}

bool jreader::_decode_number(jtoken& token, jvalue& jval)
{
	int64_t val = 0;
	bool isNeg = false;
	const char* pcur = token.pbegin;
	if ('-' == *pcur) {
		pcur++;
		isNeg = true;
	}
	for (const char* p = pcur; p != token.pend; p++) {
		char c = *p;
		if ('.' == c || 'e' == c || 'E' == c) {
			return _decode_double(token, jval);
		} else if (c < '0' || c > '9') {
			return _add_error("'" + string(token.pbegin, token.pend) + "' is not a number.", token.pbegin);
		} else {
			val = val * 10 + (c - '0');
		}
	}
	jval = isNeg ? -val : val;
	return true;
}

bool jreader::_decode_double(jtoken& token, jvalue& jval)
{
	const size_t buf_len = 64;
	size_t len = size_t(token.pend - token.pbegin);
	if (len < buf_len) {
		char buf[buf_len] = { 0 };
		::memcpy(buf, token.pbegin, len);
		buf[len] = 0;
		double val = 0;
		if (1 == sscanf_s(buf, "%lf", &val)) {
			jval = val;
			return true;
		}
	}
	return _add_error("'" + string(token.pbegin, token.pend) + "' is too large or not a number.", token.pbegin);
}

bool jreader::_decode_string(jtoken& token, string& strdec)
{
	strdec = "";
	const char* pcur = token.pbegin + 1;
	const char* pend = token.pend - 1;
	strdec.reserve(size_t(token.pend - token.pbegin));
	while (pcur != pend) {
		char c = *pcur++;
		if ('\\' == c) {
			if (pcur != pend) {
				char escape = *pcur++;
				switch (escape) {
				case '"':
					strdec += '"';
					break;
				case '\\':
					strdec += '\\';
					break;
				case 'b':
					strdec += '\b';
					break;
				case 'f':
					strdec += '\f';
					break;
				case 'n':
					strdec += '\n';
					break;
				case 'r':
					strdec += '\r';
					break;
				case 't':
					strdec += '\t';
					break;
				case '/':
					strdec += '/';
					break;
				case 'u':
				{// based on description from http://en.wikipedia.org/wiki/UTF-8

					string strUnic;
					strUnic.append(pcur, 4);

					pcur += 4;

					unsigned int cp = 0;
					if (1 != sscanf_s(strUnic.c_str(), "%x", &cp)) {
						return _add_error("Bad escape sequence in string", pcur);
					}

					string strUTF8;

					if (cp <= 0x7f) {
						strUTF8.resize(1);
						strUTF8[0] = static_cast<char>(cp);
					} else if (cp <= 0x7FF) {
						strUTF8.resize(2);
						strUTF8[1] = static_cast<char>(0x80 | (0x3f & cp));
						strUTF8[0] = static_cast<char>(0xC0 | (0x1f & (cp >> 6)));
					} else if (cp <= 0xFFFF) {
						strUTF8.resize(3);
						strUTF8[2] = static_cast<char>(0x80 | (0x3f & cp));
						strUTF8[1] = 0x80 | static_cast<char>((0x3f & (cp >> 6)));
						strUTF8[0] = 0xE0 | static_cast<char>((0xf & (cp >> 12)));
					} else if (cp <= 0x10FFFF) {
						strUTF8.resize(4);
						strUTF8[3] = static_cast<char>(0x80 | (0x3f & cp));
						strUTF8[2] = static_cast<char>(0x80 | (0x3f & (cp >> 6)));
						strUTF8[1] = static_cast<char>(0x80 | (0x3f & (cp >> 12)));
						strUTF8[0] = static_cast<char>(0xF0 | (0x7 & (cp >> 18)));
					}

					strdec += strUTF8;
				}
				break;
				default:
					return _add_error("Bad escape sequence in string", pcur);
					break;
				}
			} else {
				return _add_error("Empty escape sequence in string", pcur);
			}
		} else if ('"' == c) {
			break;
		} else {
			strdec += c;
		}
	}
	return true;
}

bool jreader::_add_error(const string& message, const char* ploc)
{
	m_perror = ploc;
	m_strerr = message;
	return false;
}

char jreader::_get_next_char()
{
	return (m_pcursor == m_pend) ? 0 : *m_pcursor++;
}

void jreader::error(string& strmsg) const
{
	strmsg = "";
	int row = 1;
	const char* pcur = m_pbegin;
	const char* plast = m_pbegin;
	while (pcur < m_perror && pcur <= m_pend) {
		char c = *pcur++;
		if (c == '\r' || c == '\n') {
			if (c == '\r' && *pcur == '\n') {
				pcur++;
			}
			row++;
			plast = pcur;
		}
	}
	char msg[64] = { 0 };
	::snprintf(msg, 64, "error: line %d, column %d, ", row, int(m_perror - plast) + 1);
	strmsg += msg + m_strerr + "\n";
}

jwriter::jwriter()
{
	m_tab = "\t";
	m_add_child = false;
}

// Class Writer
// //////////////////////////////////////////////////////////////////
void jwriter::write(const jvalue& jval, string& strdoc)
{
	strdoc = "";
	_write_value(jval, strdoc);
}

void jwriter::_write_value(const jvalue& jval, string& strdoc)
{
	switch (jval.type()) {
	case jvalue::E_NULL:
		strdoc += "null";
		break;
	case jvalue::E_INT:
		strdoc += v2s(jval.as_int64());
		break;
	case jvalue::E_BOOL:
		strdoc += jval.as_bool() ? "true" : "false";
		break;
	case jvalue::E_FLOAT:
		strdoc += v2s(jval.as_double());
		break;
	case jvalue::E_STRING:
		strdoc += v2s(jval.as_cstr());
		break;
	case jvalue::E_ARRAY:
	{
		strdoc += "[";
		size_t usize = jval.size();
		for (size_t i = 0; i < usize; i++) {
			strdoc += (i > 0) ? "," : "";
			_write_value(jval[i], strdoc);
		}
		strdoc += "]";
	}
	break;
	case jvalue::E_OBJECT:
	{
		strdoc += "{";
		vector<string> keys;
		jval.get_keys(keys);
		size_t num_key = keys.size();
		for (size_t i = 0; i < num_key; i++) {
			const string& key_name = keys[i];
			strdoc += (i > 0) ? "," : "";
			strdoc += v2s(key_name.c_str()) + ":";
			_write_value(jval[key_name.c_str()], strdoc);
		}
		strdoc += "}";
	}
	break;
	case jvalue::E_DATE:
	{
		strdoc += "\"date:";
		strdoc += d2s(jval.as_date());
		strdoc += "\"";
	}
	break;
	case jvalue::E_DATA:
	{
		strdoc += "\"data:";
		const string& data = jval.as_data();
		jbase64 b64;
		strdoc += b64.encode(data.data(), (int)data.size());
		strdoc += "\"";
	}
	break;
	}
}

const string& jwriter::style_write(const jvalue& jval)
{
	m_strdoc = "";
	m_indent = "";
	m_add_child = false;
	_style_write_value(jval);
	m_strdoc += "\n";
	return m_strdoc;
}

void jwriter::_style_write_value(const jvalue& jval)
{
	switch (jval.type()) {
	case jvalue::E_NULL:
		_push_value("null");
		break;
	case jvalue::E_INT:
		_push_value(v2s(jval.as_int64()));
		break;
	case jvalue::E_BOOL:
		_push_value(jval.as_bool() ? "true" : "false");
		break;
	case jvalue::E_FLOAT:
		_push_value(v2s(jval.as_double()));
		break;
	case jvalue::E_STRING:
		_push_value(v2s(jval.as_cstr()));
		break;
	case jvalue::E_ARRAY:
		_style_write_array_value(jval);
		break;
	case jvalue::E_OBJECT:
	{
		vector<string> keys;
		jval.get_keys(keys);
		if (!keys.empty()) {
			m_strdoc += "{";
			m_indent += m_tab;
			size_t num_key = keys.size();
			for (size_t i = 0; i < num_key; i++) {
				const string& key_name = keys[i];
				m_strdoc += (i > 0) ? "," : "";
				m_strdoc += '\n' + m_indent + v2s(key_name.c_str()) + ": ";
				_style_write_value(jval[key_name]);
			}
			m_indent.resize(m_indent.size() - 1);
			m_strdoc += '\n' + m_indent + "}";
		} else {
			_push_value("{}");
		}
	}
	break;
	case jvalue::E_DATE:
	{
		string strdoc;
		strdoc += "\"date:";
		strdoc += d2s(jval.as_date());
		strdoc += "\"";
		_push_value(strdoc);
	}
	break;
	case jvalue::E_DATA:
	{
		string strdoc;
		strdoc += "\"data:";
		const string& data = jval.as_data();
		jbase64 b64;
		strdoc += b64.encode(data.data(), (int)data.size());
		strdoc += "\"";
		_push_value(strdoc);
	}
	break;
	}
}

void jwriter::_style_write_array_value(const jvalue& jval)
{
	size_t usize = jval.size();
	if (usize > 0) {
		bool isArrayMultiLine = _is_multiline_array(jval);
		if (isArrayMultiLine) {
			m_strdoc += "[";
			m_indent += m_tab;
			bool hasChildValue = !m_child_values.empty();
			for (size_t i = 0; i < usize; i++) {
				m_strdoc += (i > 0) ? "," : "";
				if (hasChildValue) {
					m_strdoc += '\n' + m_indent + m_child_values[i];
				} else {
					m_strdoc += '\n' + m_indent;
					_style_write_value(jval[i]);
				}
			}
			m_indent.resize(m_indent.size() - 1);
			m_strdoc += '\n' + m_indent + "]";
		} else {
			m_strdoc += "[ ";
			for (size_t i = 0; i < usize; ++i) {
				m_strdoc += (i > 0) ? ", " : "";
				m_strdoc += m_child_values[i];
			}
			m_strdoc += " ]";
		}
	} else {
		_push_value("[]");
	}
}

bool jwriter::_is_multiline_array(const jvalue& jval)
{
	m_child_values.clear();
	size_t usize = jval.size();
	bool is_multiline = (usize >= 25);
	if (!is_multiline) {
		for (size_t i = 0; i < usize; i++) {
			if (jval[i].size() > 0) {
				is_multiline = true;
				break;
			}
		}
	}
	if (!is_multiline) {
		m_add_child = true;
		m_child_values.reserve(usize);
		size_t lineLength = 4 + (usize - 1) * 2; // '[ ' + ', '*n + ' ]'
		for (size_t i = 0; i < usize; i++) {
			_style_write_value(jval[i]);
			lineLength += m_child_values[i].length();
		}
		m_add_child = false;
		is_multiline = lineLength >= 75;
	}
	return is_multiline;
}

void jwriter::_push_value(const string& strval)
{
	if (!m_add_child) {
		m_strdoc += strval;
	} else {
		m_child_values.push_back(strval);
	}
}

string jwriter::v2s(int64_t val)
{
	char buf[32] = { 0 };
	snprintf(buf, 32, "%" PRId64, val);
	return buf;
}

string jwriter::v2s(double val)
{
	char buf[128] = { 0 };
	snprintf(buf, 128, "%g", val);
	return buf;
}

string jwriter::d2s(time_t t)
{
	t = (t > 0x7933F8EFF) ? (0x7933F8EFF - 1) : t;

	tm ft = { 0 };

#ifdef _WIN32
	localtime_s(&ft, &t);
#else
	localtime_r(&t, &ft);
#endif

	ft.tm_year = (ft.tm_year < 0) ? 0 : ft.tm_year;
	ft.tm_mon = (ft.tm_mon < 0) ? 0 : ft.tm_mon;
	ft.tm_mday = (ft.tm_mday < 0) ? 0 : ft.tm_mday;
	ft.tm_hour = (ft.tm_hour < 0) ? 0 : ft.tm_hour;
	ft.tm_min = (ft.tm_min < 0) ? 0 : ft.tm_min;
	ft.tm_sec = (ft.tm_sec < 0) ? 0 : ft.tm_sec;

	char date[64] = { 0 };
	snprintf(date, 64, "%04d-%02d-%02dT%02d:%02d:%02dZ", ft.tm_year + 1900, ft.tm_mon + 1, ft.tm_mday, ft.tm_hour, ft.tm_min, ft.tm_sec);
	return date;
}

string jwriter::v2s(const char* pstr)
{
	if (NULL != strpbrk(pstr, "\"\\\b\f\n\r\t")) {
		string ret;
		ret.reserve(strlen(pstr) * 2 + 3);
		ret += "\"";
		for (const char* c = pstr; 0 != *c; c++) {
			switch (*c) {
			case '\\':
			{
				c++;
				bool is_unicode = false;
				if ('u' == *c) {
					bool bFlag = true;
					for (int i = 1; i <= 4; i++) {
						if (!isdigit(*(c + i))) {
							bFlag = false;
							break;
						}
					}
					is_unicode = bFlag;
				}

				if (true == is_unicode) {
					ret += "\\u";
				} else {
					ret += "\\\\";
					c--;
				}
			}
			break;
			case '\"':
				ret += "\\\"";
				break;
			case '\b':
				ret += "\\b";
				break;
			case '\f':
				ret += "\\f";
				break;
			case '\n':
				ret += "\\n";
				break;
			case '\r':
				ret += "\\r";
				break;
			case '\t':
				ret += "\\t";
				break;
			default:
				ret += *c;
				break;
			}
		}
		ret += "\"";
		return ret;
	} else {
		return string("\"") + pstr + "\"";
	}
}

void jwriter::write_to_html(const jvalue& jval, string& strdoc)
{
	strdoc = "";
	_write_value_to_html(jval, strdoc);
	strdoc += "\n";
}

void jwriter::_write_value_to_html(const jvalue& jval, string& strdoc)
{

	switch (jval.type()) {
	case jvalue::E_NULL:
		strdoc += "null";
		break;
	case jvalue::E_INT:
		strdoc += v2s(jval.as_int64());
		break;
	case jvalue::E_BOOL:
		strdoc += jval.as_bool() ? "true" : "false";
		break;
	case jvalue::E_FLOAT:
		strdoc += v2s(jval.as_double());
		break;
	case jvalue::E_STRING:
		strdoc += vstring2s(jval.as_cstr()); //don't escape here, escape before
		break;
	case jvalue::E_ARRAY:
	{
		strdoc += "[";
		size_t usize = jval.size();
		for (size_t i = 0; i < usize; i++) {
			strdoc += (i > 0) ? "," : "";
			_write_value_to_html(jval[i], strdoc);
		}
		strdoc += "]";
	}
	break;
	case jvalue::E_OBJECT:
	{
		strdoc += "{";
		vector<string> keys;
		jval.get_keys(keys);
		size_t num_key = keys.size();
		for (size_t i = 0; i < num_key; i++) {
			const string& key_name = keys[i];
			strdoc += (i > 0) ? "," : "";
			strdoc += vstring2s(key_name.c_str()) + ":";
			_write_value_to_html(jval[key_name.c_str()], strdoc);
		}
		strdoc += "}";
	}
	break;
	case jvalue::E_DATE:
	{
		strdoc += "\\\"date:";
		strdoc += d2s(jval.as_date());
		strdoc += "\\\"";
	}
	break;
	case jvalue::E_DATA:
	{
		strdoc += "\\\"data:";
		const string& data = jval.as_data();
		jbase64 b64;
		strdoc += b64.encode(data.data(), (int)data.size());
		strdoc += "\\\"";
	}
	break;
	}
}

string jwriter::vstring2s(const char* pstr)
{
	return string("\\\"") + pstr + "\\\"";

}

string jwriter::vstring2html(const char* pstr)
{

	if (NULL != strpbrk(pstr, "<>\"")) {
		string ret;
		ret.reserve(strlen(pstr) * 2 + 3);
		ret += "\\\"";
		for (const char* c = pstr; 0 != *c; c++) {
			switch (*c) {
			case '<':
				ret += "&lt;";
				break;
			case '>':
				ret += "&gt;";
				break;
			case '\"':
				ret += "&quot;";
				break;
				//	case '&':	ret += "&amp;";	break;
			default:
				ret += *c;
				break;
			}
		}
		ret += "\\\"";
		return ret;
	} else {
		return string("\\\"") + pstr + "\\\"";
	}

}

namespace {
bool plistSpace(char c) { return c == ' ' || c == '\t' || c == '\r' || c == '\n'; }

bool xmlScalar(uint32_t value) {
    return value == 9 || value == 10 || value == 13 || (value >= 0x20 && value <= 0xd7ff) ||
        (value >= 0xe000 && value <= 0xfffd) || (value >= 0x10000 && value <= 0x10ffff);
}

bool appendXMLScalar(string& output, uint32_t value) {
    if (!xmlScalar(value)) return false;
    if (value < 0x80) output.push_back(static_cast<char>(value));
    else if (value < 0x800) {
        output.push_back(static_cast<char>(0xc0 | (value >> 6)));
        output.push_back(static_cast<char>(0x80 | (value & 0x3f)));
    } else if (value < 0x10000) {
        output.push_back(static_cast<char>(0xe0 | (value >> 12)));
        output.push_back(static_cast<char>(0x80 | ((value >> 6) & 0x3f)));
        output.push_back(static_cast<char>(0x80 | (value & 0x3f)));
    } else {
        output.push_back(static_cast<char>(0xf0 | (value >> 18)));
        output.push_back(static_cast<char>(0x80 | ((value >> 12) & 0x3f)));
        output.push_back(static_cast<char>(0x80 | ((value >> 6) & 0x3f)));
        output.push_back(static_cast<char>(0x80 | (value & 0x3f)));
    }
    return true;
}

bool validXMLUTF8(const char* bytes, size_t length) {
    for (size_t index = 0; index < length;) {
        const uint8_t first = static_cast<uint8_t>(bytes[index++]);
        uint32_t scalar = first;
        size_t following = 0;
        uint32_t minimum = 0;
        if (first < 0x80) {}
        else if (first >= 0xc2 && first <= 0xdf) { following = 1; scalar &= 0x1f; minimum = 0x80; }
        else if (first >= 0xe0 && first <= 0xef) { following = 2; scalar &= 0x0f; minimum = 0x800; }
        else if (first >= 0xf0 && first <= 0xf4) { following = 3; scalar &= 7; minimum = 0x10000; }
        else return false;
        if (following > length - index) return false;
        for (size_t count = 0; count < following; ++count) {
            const uint8_t next = static_cast<uint8_t>(bytes[index++]);
            if ((next & 0xc0) != 0x80) return false;
            scalar = (scalar << 6) | (next & 0x3f);
        }
        if (scalar < minimum || !xmlScalar(scalar)) return false;
    }
    return true;
}

bool plistUTCDate(const string& text, time_t& result) {
    // XML plist dates are UTC. mktime normalizes invalid calendars and applies
    // the host timezone, so it must never admit signing-profile dates here.
    if (text.size() != 20 || text[4] != '-' || text[7] != '-' || text[10] != 'T' ||
        text[13] != ':' || text[16] != ':' || text[19] != 'Z') return false;
    auto number = [&](size_t offset, size_t count) -> int {
        int value = 0;
        for (size_t index = offset; index < offset + count; ++index) {
            if (text[index] < '0' || text[index] > '9') return -1;
            value = value * 10 + text[index] - '0';
        }
        return value;
    };
    const int year = number(0, 4), month = number(5, 2), day = number(8, 2);
    const int hour = number(11, 2), minute = number(14, 2), second = number(17, 2);
    const bool leap = year % 4 == 0 && (year % 100 != 0 || year % 400 == 0);
    static const int monthDays[] = {31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31};
    if (year < 1 || month < 1 || month > 12 || day < 1 || day > monthDays[month - 1] + (month == 2 && leap) ||
        hour < 0 || hour > 23 || minute < 0 || minute > 59 || second < 0 || second > 59) return false;
    const int64_t priorYear = year - 1;
    int64_t days = 365 * priorYear + priorYear / 4 - priorYear / 100 + priorYear / 400 - 719162;
    for (int current = 1; current < month; ++current) days += monthDays[current - 1] + (current == 2 && leap);
    days += day - 1;
    const int64_t seconds = days * 86400 + hour * 3600 + minute * 60 + second;
    if (static_cast<long double>(seconds) < static_cast<long double>(numeric_limits<time_t>::lowest()) ||
        static_cast<long double>(seconds) > static_cast<long double>(numeric_limits<time_t>::max())) return false;
    result = static_cast<time_t>(seconds);
    return true;
}
} // namespace

//////////////////////////////////////////////////////////////////////////
jpreader::jpreader()
{
	//xml
	m_pbegin = NULL;
	m_pend = NULL;
	m_pcursor = NULL;
	m_perror = NULL;

	//binary
	m_ptrailer = NULL;
	m_num_objects = 0;
	m_offset_table_offset_size = 0;
	m_poffset_table = 0;
	m_object_ref_size = 0;
	m_top_object_offset = 0;
}

bool jpreader::parse(const char* pdoc, size_t len, jvalue& root, bool* is_binary)
{
    root.clear();
    struct ClearOnFailure {
        jvalue& value; bool succeeded = false;
        ~ClearOnFailure() { if (!succeeded) value.clear(); }
    } output{root};
    m_pbegin = m_pend = m_pcursor = m_perror = NULL;
    m_strerr = "Invalid or unsupported plist";
    if (is_binary) *is_binary = false;
    if (!pdoc || len == 0 || len > 64 * 1024 * 1024) return false;
    m_depth = 0; m_remaining = 200000; m_has_plist = false;
    if (len >= 8 && memcmp(pdoc, "bplist00", 8) == 0) {
        if (is_binary) *is_binary = true;
        output.succeeded = parse_binary(pdoc, len, root);
        return output.succeeded;
    }
    m_pbegin = pdoc; m_pend = pdoc + len; m_pcursor = m_perror = pdoc;
    if (!validXMLUTF8(pdoc, len)) return false;
    if (len >= 3 && memcmp(pdoc, "\xef\xbb\xbf", 3) == 0) m_pcursor += 3;
    ptoken token;
    if (!_read_token(token) || !_read_value(root, token)) return false;
    if (m_has_plist) {
        ptoken end;
        if (!_read_token(end) || end.type != ptoken::E_PTOKEN_END) return false;
    }
    _skip_spaces();
    while (m_pcursor != m_pend) {
        string label;
        if (!_read_label(label) || (label != "<!comment>" && label != "<?instruction>")) return false;
        _skip_spaces();
    }
    output.succeeded = true;
    return output.succeeded;
}

bool jpreader::_read_value(jvalue& pval, ptoken& token)
{
    if (m_depth >= 64 || m_remaining == 0) return false;
    ++m_depth; --m_remaining;
    struct Depth { size_t& value; ~Depth() { --value; } } depth{m_depth};
	switch (token.type) {
	case ptoken::E_PTOKEN_TRUE:
		pval = true;
		break;
	case ptoken::E_PTOKEN_FALSE:
		pval = false;
		break;
	case ptoken::E_PTOKEN_NULL:
		pval = jvalue();
		break;
	case ptoken::E_PTOKEN_STRING_NULL:
		pval = jvalue(jvalue::E_STRING);
		break;
	case ptoken::E_PTOKEN_DICTIONARY_NULL:
		pval = jvalue(jvalue::E_OBJECT);
		break;
	case ptoken::E_PTOKEN_ARRAY_NULL:
		pval = jvalue(jvalue::E_ARRAY);
		break;
	case ptoken::E_PTOKEN_DATA_NULL:
		pval = jvalue(jvalue::E_DATA);
		break;
    case ptoken::E_PTOKEN_DATE_NULL:
    case ptoken::E_PTOKEN_INTEGER_NULL:
    case ptoken::E_PTOKEN_REAL_NULL:
        return false;
	case ptoken::E_PTOKEN_NUMBER:
		return _decode_number(token, pval);
		break;
	case ptoken::E_PTOKEN_ARRAY_BEGIN:
		return _read_array(pval);
		break;
	case ptoken::E_PTOKEN_DICTIONARY_BEGIN:
		return _read_dictionary(pval);
		break;
	case ptoken::E_PTOKEN_DATE:
	{
		string strval;
        time_t date;
        if (!_decode_string(token, strval) || !plistUTCDate(strval, date)) return false;
        pval.assign_date(date);
	}
	break;
    case ptoken::E_PTOKEN_DATA:
    {
        // XML plist data permits only XML whitespace between canonical base64
        // characters. Normalize it here, not in the general strict decoder.
        string encoded;
        for (const char* cursor = token.pbegin; cursor != token.pend; ++cursor) {
            const char c = *cursor;
            if (c != ' ' && c != '\t' && c != '\r' && c != '\n') encoded.push_back(c);
        }
        jbase64 codec;
        int length = 0;
        const char* bytes = codec.decode(encoded.c_str(), static_cast<int>(encoded.size()), &length);
        if (!encoded.empty() && length == 0) return _add_error("Invalid plist base64 data", token.pbegin);
        pval.assign_data(bytes, static_cast<size_t>(length));
    }
    break;
	case ptoken::E_PTOKEN_STRING:
	{
		string strval;
        if (!_decode_string(token, strval)) return false;
		pval = strval.c_str();
	}
	break;
	default:
		return _add_error("Syntax error: value, dictionary or array expected.", token.pbegin);
		break;
	}
	return true;
}

bool jpreader::_read_label(string& label)
{
    _skip_spaces();
    if (m_pcursor == m_pend || *m_pcursor++ != '<') return false;
    const char* start = m_pcursor;
    auto begins = [&](const char* text, size_t length) {
        return length <= static_cast<size_t>(m_pend - start) && memcmp(start, text, length) == 0;
    };
    if (begins("!--", 3)) {
        const char* end = std::search(start + 3, m_pend, "-->", "-->" + 3);
        if (end == m_pend || std::search(start + 3, end, "--", "--" + 2) != end) return false;
        m_pcursor = end + 3; label = "<!comment>"; return true;
    }
    if (begins("?", 1)) {
        const char* end = std::search(start + 1, m_pend, "?>", "?>" + 2);
        if (end == m_pend) return false;
        // No external resource is fetched. Unknown encodings are unsupported;
        // the bytes were already validated as UTF-8 before tokenization.
        const string instruction(start + 1, end);
        const size_t encoding = instruction.find("encoding");
        if (encoding != string::npos) {
            const size_t equals = instruction.find('=', encoding + 8);
            if (equals == string::npos) return false;
            const size_t quote = instruction.find_first_not_of(" \t\r\n", equals + 1);
            if (quote == string::npos || (instruction[quote] != '\'' && instruction[quote] != '"')) return false;
            const size_t close = instruction.find(instruction[quote], quote + 1);
            if (close == string::npos) return false;
            const string charset = instruction.substr(quote + 1, close - quote - 1);
            if (charset != "UTF-8" && charset != "utf-8") return false;
        }
        m_pcursor = end + 2; label = "<?instruction>"; return true;
    }
    if (begins("!DOCTYPE", 8)) {
        if (m_depth != 0 || m_has_plist) return false;
        // Accept the ordinary plist declaration, never an internal entity DTD.
        const char* cursor = start + 8;
        if (cursor == m_pend || !plistSpace(*cursor)) return false;
        while (cursor != m_pend && plistSpace(*cursor)) ++cursor;
        if (m_pend - cursor < 5 || memcmp(cursor, "plist", 5) != 0) return false;
        cursor += 5;
        if (cursor == m_pend || (!plistSpace(*cursor) && *cursor != '>')) return false;
        char quote = 0;
        for (; cursor != m_pend; ++cursor) {
            const char current = *cursor;
            if (quote) { if (current == quote) quote = 0; }
            else if (current == '\'' || current == '"') quote = current;
            else if (current == '[' || current == '<') return false;
            else if (current == '>') { m_pcursor = cursor + 1; label = "<!doctype>"; return true; }
        }
        return false;
    }
    bool closing = false;
    if (m_pcursor != m_pend && *m_pcursor == '/') { closing = true; ++m_pcursor; }
    const char* name = m_pcursor;
    while (m_pcursor != m_pend && ((*m_pcursor >= 'a' && *m_pcursor <= 'z') || (*m_pcursor >= 'A' && *m_pcursor <= 'Z'))) ++m_pcursor;
    if (m_pcursor == name) return false;
    const string tag(name, m_pcursor);
    _skip_spaces();
    if (tag == "plist" && !closing && m_pcursor != m_pend && *m_pcursor != '/' && *m_pcursor != '>') {
        if (m_pend - m_pcursor < 7 || memcmp(m_pcursor, "version", 7) != 0) return false;
        m_pcursor += 7; _skip_spaces();
        if (m_pcursor == m_pend || *m_pcursor++ != '=') return false;
        _skip_spaces();
        if (m_pcursor == m_pend || (*m_pcursor != '\'' && *m_pcursor != '"')) return false;
        const char quote = *m_pcursor++;
        if (m_pend - m_pcursor < 4 || memcmp(m_pcursor, "1.0", 3) != 0 || m_pcursor[3] != quote) return false;
        m_pcursor += 4; _skip_spaces();
    }
    bool empty = false;
    if (!closing && m_pcursor != m_pend && *m_pcursor == '/') { empty = true; ++m_pcursor; }
    if (m_pcursor == m_pend || *m_pcursor++ != '>') return false;
    label = string("<") + (closing ? "/" : "") + tag + (empty ? "/" : "") + ">";
    return true;
}

void jpreader::_end_label(ptoken& token, const char* end_label)
{
	string label;
	_read_label(label);
	if (end_label != label) {
		token.type = ptoken::E_PTOKEN_ERROR;
	}
}

bool jpreader::_read_token(ptoken& token)
{
    // Skip prolog/doctype without recursive calls controlled by input length.
    for (;;) {
    string label;
    if (!_read_label(label) || label.size() < 3) {
        token.type = ptoken::E_PTOKEN_ERROR;
        return false;
    }
    if ('?' == label[1] || '!' == label[1]) continue;
    if ("<plist>" == label) {
        if (m_depth != 0 || m_has_plist) return false;
        m_has_plist = true;
        continue;
    }

	if ("<dict>" == label) {
		token.type = ptoken::E_PTOKEN_DICTIONARY_BEGIN;
	} else if ("</dict>" == label) {
		token.type = ptoken::E_PTOKEN_DICTIONARY_END;
	} else if ("<array>" == label) {
		token.type = ptoken::E_PTOKEN_ARRAY_BEGIN;
	} else if ("</array>" == label) {
		token.type = ptoken::E_PTOKEN_ARRAY_END;
	} else if ("<key>" == label) {
		token.pbegin = m_pcursor;
		token.type = _read_string() ? ptoken::E_PTOKEN_KEY : ptoken::E_PTOKEN_ERROR;
		token.pend = m_pcursor;
		_end_label(token, "</key>");
	} else if ("<string>" == label) {
		token.pbegin = m_pcursor;
		token.type = _read_string() ? ptoken::E_PTOKEN_STRING : ptoken::E_PTOKEN_ERROR;
		token.pend = m_pcursor;
		_end_label(token, "</string>");
	} else if ("<date>" == label) {
		token.pbegin = m_pcursor;
		token.type = _read_string() ? ptoken::E_PTOKEN_DATE : ptoken::E_PTOKEN_ERROR;
		token.pend = m_pcursor;
		_end_label(token, "</date>");
	} else if ("<data>" == label) {
		token.pbegin = m_pcursor;
		token.type = _read_string() ? ptoken::E_PTOKEN_DATA : ptoken::E_PTOKEN_ERROR;
		token.pend = m_pcursor;
		_end_label(token, "</data>");
	} else if ("<integer>" == label) {
        token.real = false;
		token.pbegin = m_pcursor;
		token.type = _read_number() ? ptoken::E_PTOKEN_NUMBER : ptoken::E_PTOKEN_ERROR;
		token.pend = m_pcursor;
		_end_label(token, "</integer>");
	} else if ("<real>" == label) {
        token.real = true;
		token.pbegin = m_pcursor;
		token.type = _read_number() ? ptoken::E_PTOKEN_NUMBER : ptoken::E_PTOKEN_ERROR;
		token.pend = m_pcursor;
		_end_label(token, "</real>");
	} else if ("<true/>" == label || "<true>" == label) {
		token.type = ptoken::E_PTOKEN_TRUE;
        if (label == "<true>") _end_label(token, "</true>");
	} else if ("<false/>" == label || "<false>" == label) {
		token.type = ptoken::E_PTOKEN_FALSE;
        if (label == "<false>") _end_label(token, "</false>");
	} else if ("<dict/>" == label) {
		token.type = ptoken::E_PTOKEN_DICTIONARY_NULL;
	} else if ("<array/>" == label) {
		token.type = ptoken::E_PTOKEN_ARRAY_NULL;
	} else if ("<data/>" == label) {
		token.type = ptoken::E_PTOKEN_DATA_NULL;
	} else if ("<date/>" == label) {
		token.type = ptoken::E_PTOKEN_DATE_NULL;
	} else if ("<integer/>" == label) {
		token.type = ptoken::E_PTOKEN_INTEGER_NULL;
	} else if ("<real/>" == label) {
		token.type = ptoken::E_PTOKEN_REAL_NULL;
    } else if ("<key/>" == label) {
        token.type = ptoken::E_PTOKEN_KEY;
        token.pbegin = token.pend = m_pcursor;
	} else if ("<string/>" == label) {
		token.type = ptoken::E_PTOKEN_STRING_NULL;
	} else if ("</plist>" == label || "<plist/>" == label) {
		token.type = ptoken::E_PTOKEN_END;
	} else {
		token.type = ptoken::E_PTOKEN_ERROR;
	}

	return true;
    }
}

void jpreader::_skip_spaces()
{
	while (m_pcursor != m_pend) {
		char c = *m_pcursor;
		if (c == ' ' || c == '\t' || c == '\r' || c == '\n') {
			m_pcursor++;
		} else {
			break;
		}
	}
}

bool jpreader::_read_number()
{
    return _read_string(); // Grammar/type/range are checked on the entire token.
}

bool jpreader::_read_string()
{
	while (m_pcursor != m_pend) {
		if ('<' == *m_pcursor) {
			break;
		}
		m_pcursor++;
	}
    return m_pcursor != m_pend && '<' == *m_pcursor;
}

bool jpreader::_read_dictionary(jvalue& pval)
{
	ptoken key;
	string strkey;
	if (jvalue::E_OBJECT != pval.type()) {
		pval = jvalue(jvalue::E_OBJECT);
	}
	while (_read_token(key)) {
		if (ptoken::E_PTOKEN_DICTIONARY_END == key.type) {//empty
			return true;
		}

		if (ptoken::E_PTOKEN_KEY != key.type) {
			break;
		}

		strkey = "";
		if (!_decode_string(key, strkey)) {
			return false;
		}

        if (pval.has(strkey)) return false;
		ptoken val;
        if (!_read_token(val)) return false;
		if (!_read_value(pval[strkey.c_str()], val)) {
			return false;
		}
	}
	return _add_error("missing '</dict>' or dictionary member name", key.pbegin);
}

bool jpreader::_read_array(jvalue& pval)
{
    pval = jvalue(jvalue::E_ARRAY);
    for (;;) {
        ptoken token;
        if (!_read_token(token)) return false;
        if (token.type == ptoken::E_PTOKEN_ARRAY_END) return true;
        jvalue child;
        if (!_read_value(child, token)) return false;
        pval.push_back(child);
    }
}

bool jpreader::_decode_number(ptoken& token, jvalue& pval)
{
    if (token.real) return _decode_double(token, pval);
    const char* cursor = token.pbegin;
    const char* end = token.pend;
    while (cursor != end && plistSpace(*cursor)) ++cursor;
    while (cursor != end && plistSpace(end[-1])) --end;
    bool negative = false;
    if (cursor != end && (*cursor == '-' || *cursor == '+')) negative = *cursor++ == '-';
    if (cursor == end) return false;
    const uint64_t limit = static_cast<uint64_t>(numeric_limits<int64_t>::max()) + (negative ? 1ULL : 0ULL);
    uint64_t value = 0;
    for (; cursor != end; ++cursor) {
        if (*cursor < '0' || *cursor > '9') return false;
        const uint64_t digit = static_cast<uint64_t>(*cursor - '0');
        if (value > (limit - digit) / 10) return false;
        value = value * 10 + digit;
    }
    pval = negative ? (value == (1ULL << 63) ? numeric_limits<int64_t>::min() : -static_cast<int64_t>(value)) : static_cast<int64_t>(value);
    return true;
}

bool jpreader::_decode_double(ptoken& token, jvalue& pval)
{
    const char* cursor = token.pbegin;
    const char* end = token.pend;
    while (cursor != end && plistSpace(*cursor)) ++cursor;
    while (cursor != end && plistSpace(end[-1])) --end;
    if (cursor == end || end - cursor > 128) return false;
    const char* start = cursor;
    if (*cursor == '+' || *cursor == '-') ++cursor;
    bool digits = false;
    while (cursor != end && *cursor >= '0' && *cursor <= '9') { digits = true; ++cursor; }
    if (cursor != end && *cursor == '.') {
        ++cursor;
        while (cursor != end && *cursor >= '0' && *cursor <= '9') { digits = true; ++cursor; }
    }
    if (!digits) return false;
    if (cursor != end && (*cursor == 'e' || *cursor == 'E')) {
        ++cursor;
        if (cursor != end && (*cursor == '+' || *cursor == '-')) ++cursor;
        const char* exponent = cursor;
        while (cursor != end && *cursor >= '0' && *cursor <= '9') ++cursor;
        if (cursor == exponent) return false;
    }
    if (cursor != end) return false;
    istringstream stream(string(start, end));
    stream.imbue(locale::classic());
    double value;
    if (!(stream >> noskipws >> value) || !stream.eof() || !isfinite(value)) return false;
    pval = value;
    return true;
}

bool jpreader::_decode_string(ptoken& token, string& output)
{
    const char* cursor = token.pbegin;
    const char* end = token.pend;
    output.clear(); output.reserve(static_cast<size_t>(end - cursor));
    while (cursor != end) {
        const char current = *cursor++;
        if (current == '&') {
            const char* terminator = std::find(cursor, end, ';');
            if (terminator == end || terminator - cursor > 16) return false;
            const string entity(cursor, terminator);
            if (entity == "amp") output.push_back('&');
            else if (entity == "lt") output.push_back('<');
            else if (entity == "gt") output.push_back('>');
            else if (entity == "quot") output.push_back('"');
            else if (entity == "apos") output.push_back('\'');
            else if (!entity.empty() && entity[0] == '#') {
                size_t index = 1;
                const uint32_t base = index < entity.size() && entity[index] == 'x' ? (++index, 16) : 10;
                if (index == entity.size()) return false;
                uint32_t scalar = 0;
                for (; index < entity.size(); ++index) {
                    const char c = entity[index];
                    const uint32_t digit = c >= '0' && c <= '9' ? c - '0' :
                        (base == 16 && c >= 'a' && c <= 'f' ? c - 'a' + 10 :
                         (base == 16 && c >= 'A' && c <= 'F' ? c - 'A' + 10 : 16));
                    if (digit >= base || scalar > (0x10ffff - digit) / base) return false;
                    scalar = scalar * base + digit;
                }
                if (!appendXMLScalar(output, scalar)) return false;
            } else return false;
            cursor = terminator + 1;
        } else if (current == '\r') {
            if (cursor != end && *cursor == '\n') ++cursor;
            output.push_back('\n'); // XML end-of-line normalization, not whitespace deletion.
        } else {
            if (current == ']' && end - cursor >= 2 && cursor[0] == ']' && cursor[1] == '>') return false;
            output.push_back(current);
        }
    }
    return true;
}

bool jpreader::_add_error(const string& message, const char* ploc)
{
	m_perror = ploc;
	m_strerr = message;
	return false;
}

void jpreader::error(string& strmsg) const
{
    if (!m_pbegin || !m_pend || !m_perror || m_perror < m_pbegin || m_perror > m_pend) {
        strmsg = "Invalid or unsupported plist";
        return;
    }
	strmsg = "";
	int row = 1;
	const char* pcursor = m_pbegin;
	const char* plast = m_pbegin;
	while (pcursor < m_perror && pcursor < m_pend) {
		char c = *pcursor++;
		if (c == '\r' || c == '\n') {
			if (c == '\r' && pcursor < m_pend && *pcursor == '\n') {
				pcursor++;
			}
			row++;
			plast = pcursor;
		}
	}
	char msg[64] = { 0 };
	::snprintf(msg, 64, "error: line %d, column %d, ", row, int(m_perror - plast) + 1);
	strmsg += msg + m_strerr + "\n";
}

//////////////////////////////////////////////////////////////////////////
uint32_t jpreader::_get_uint24_from_be(const char* value)
{
    return static_cast<uint32_t>(_get_uint_val(value, 3));
}

uint64_t jpreader::_get_uint_val(const char* value, size_t size)
{
    // Binary plist object/offset tables are not naturally aligned. Byte reads
    // avoid undefined unaligned word accesses on both Apple and portable hosts.
    uint64_t result = 0;
    for (size_t index = 0; index < size; ++index)
        result = (result << 8) | static_cast<unsigned char>(value[index]);
    return result;
}

bool jpreader::_read_uint_size(const char*& cursor, size_t& size)
{
    if (cursor >= m_poffset_table) return false;
    const uint8_t marker = static_cast<uint8_t>(*cursor++);
    if ((marker & 0xf0) != NS_NUMBER_INT || (marker & 0x0f) > 3) return false;
    const size_t width = size_t(1) << (marker & 0x0f);
    if (width > static_cast<size_t>(m_poffset_table - cursor)) return false;
    const uint64_t value = _get_uint_val(cursor, width);
    cursor += width;
    if (value > std::numeric_limits<size_t>::max()) return false;
    size = static_cast<size_t>(value);
    return true;
}

bool jpreader::_read_unicode(const char* cursor, size_t size, jvalue& value)
{
    if (size > static_cast<size_t>(m_poffset_table - cursor) / 2) return false;
    string output;
    for (size_t index = 0; index < size; ++index) {
        uint32_t scalar = static_cast<uint32_t>(_get_uint_val(cursor + index * 2, 2));
        if (scalar >= 0xd800 && scalar <= 0xdbff) {
            if (++index >= size) return false;
            uint32_t low = static_cast<uint32_t>(_get_uint_val(cursor + index * 2, 2));
            if (low < 0xdc00 || low > 0xdfff) return false;
            scalar = 0x10000 + ((scalar - 0xd800) << 10) + low - 0xdc00;
        } else if (scalar >= 0xdc00 && scalar <= 0xdfff) return false;
        // This legacy value representation uses NUL-terminated strings. Reject
        // embedded NUL rather than silently changing dictionary keys/values.
        if (scalar == 0) return false;
        if (scalar < 0x80) output.push_back(static_cast<char>(scalar));
        else if (scalar < 0x800) {
            output.push_back(static_cast<char>(0xc0 | (scalar >> 6)));
            output.push_back(static_cast<char>(0x80 | (scalar & 0x3f)));
        } else if (scalar < 0x10000) {
            output.push_back(static_cast<char>(0xe0 | (scalar >> 12)));
            output.push_back(static_cast<char>(0x80 | ((scalar >> 6) & 0x3f)));
            output.push_back(static_cast<char>(0x80 | (scalar & 0x3f)));
        } else {
            output.push_back(static_cast<char>(0xf0 | (scalar >> 18)));
            output.push_back(static_cast<char>(0x80 | ((scalar >> 12) & 0x3f)));
            output.push_back(static_cast<char>(0x80 | ((scalar >> 6) & 0x3f)));
            output.push_back(static_cast<char>(0x80 | (scalar & 0x3f)));
        }
    }
    value = output;
    return true;
}

bool jpreader::_read_binary_value(const char*& cursor, jvalue& value)
{
    if (cursor < m_pbegin + 8 || cursor >= m_poffset_table || m_depth >= 64 || m_remaining == 0) return false;
    ++m_depth; --m_remaining;
    struct Depth { size_t& value; ~Depth() { --value; } } depth{m_depth};
    const uint8_t marker = static_cast<uint8_t>(*cursor++);
    const uint8_t type = marker & 0xf0, small = marker & 0x0f;
    auto available = [&](size_t length) { return length <= static_cast<size_t>(m_poffset_table - cursor); };
    auto object = [&](uint64_t index, jvalue& output) {
        if (index >= m_num_objects) return false;
        const uint64_t offset = _get_uint_val(m_poffset_table + index * m_offset_table_offset_size, m_offset_table_offset_size);
        if (offset < 8 || offset >= static_cast<uint64_t>(m_poffset_table - m_pbegin)) return false;
        const char* address = m_pbegin + static_cast<size_t>(offset);
        return _read_binary_value(address, output);
    };
    if (type == BPLIST_NULL) {
        if (small == 0) { value = jvalue(); return true; }
        if (small == NS_NUMBER_FALSE || small == NS_NUMBER_TRUE) { value = small == NS_NUMBER_TRUE; return true; }
        return false;
    }
    if (type == NS_NUMBER_INT) {
        if (small > 3) return false;
        const size_t width = size_t(1) << small;
        if (!available(width)) return false;
        value = static_cast<int64_t>(_get_uint_val(cursor, width)); cursor += width;
        return true;
    }
    if (type == NS_NUMBER_REAL || type == NS_DATE) {
        if ((small != 2 && small != 3) || (type == NS_DATE && small != 3)) return false;
        const size_t width = size_t(1) << small;
        if (!available(width)) return false;
        double number = 0;
        if (width == 4) {
            uint32_t bits = static_cast<uint32_t>(_get_uint_val(cursor, 4));
            float real; memcpy(&real, &bits, 4); number = real;
        } else {
            uint64_t bits = _get_uint_val(cursor, 8); memcpy(&number, &bits, 8);
        }
        cursor += width;
        if (!std::isfinite(number)) return false;
        if (type == NS_DATE) {
            number += 978307200.0; // 2001-01-01 00:00:00 UTC, not a local timezone.
            if (number < static_cast<double>(std::numeric_limits<time_t>::lowest()) ||
                number >= static_cast<double>(std::numeric_limits<time_t>::max())) return false;
            value.assign_date(static_cast<time_t>(number));
        } else value = number;
        return true;
    }
    size_t size = small;
    if (small == 0x0f && !_read_uint_size(cursor, size)) return false;
    switch (type) {
    case NS_DATA:
        if (!available(size)) return false;
        value.assign_data(cursor, size); cursor += size;
        return true;
    case NS_STRING_ASCII:
        if (!available(size) || memchr(cursor, 0, size)) return false;
        if (type == NS_STRING_ASCII) {
            for (size_t index = 0; index < size; ++index) if (static_cast<unsigned char>(cursor[index]) > 0x7f) return false;
        }
        value = string(cursor, size); cursor += size;
        return true;
    case NS_STRING_UNICODE:
        if (size > static_cast<size_t>(m_poffset_table - cursor) / 2 || !_read_unicode(cursor, size, value)) return false;
        cursor += size * 2;
        return true;
    case NS_ARRAY:
        if (size > m_remaining || size > static_cast<size_t>(m_poffset_table - cursor) / m_object_ref_size) return false;
        value = jvalue(jvalue::E_ARRAY);
        for (size_t index = 0; index < size; ++index) {
            jvalue child;
            if (!object(_get_uint_val(cursor + index * m_object_ref_size, m_object_ref_size), child)) return false;
            value.push_back(child);
        }
        cursor += size * m_object_ref_size;
        return true;
    case NS_DICTIONARY:
        if (size > m_remaining / 2 || size > static_cast<size_t>(m_poffset_table - cursor) / m_object_ref_size / 2) return false;
        value = jvalue(jvalue::E_OBJECT);
        for (size_t index = 0; index < size; ++index) {
            jvalue key, child;
            if (!object(_get_uint_val(cursor + index * m_object_ref_size, m_object_ref_size), key) || !key.is_string() || value.has(key.as_cstr()) ||
                !object(_get_uint_val(cursor + (index + size) * m_object_ref_size, m_object_ref_size), child)) return false;
            value[key.as_cstr()] = child;
        }
        cursor += size * m_object_ref_size * 2;
        return true;
    default: return false; // UID/URL/UUID/custom types are not signing property lists.
    }
}

bool jpreader::parse_binary(const char* bytes, size_t length, jvalue& value)
{
    value.clear();
    if (!bytes || length < 40 || length > 64 * 1024 * 1024 || memcmp(bytes, "bplist00", 8) != 0) return false;
    m_pbegin = bytes; m_pend = bytes + length; m_ptrailer = m_pend - 32;
    m_perror = bytes; m_strerr = "Invalid or unsupported binary plist";
    m_depth = 0; m_remaining = 200000;
    m_offset_table_offset_size = static_cast<uint8_t>(m_ptrailer[6]);
    m_object_ref_size = static_cast<uint8_t>(m_ptrailer[7]);
    m_num_objects = _get_uint_val(m_ptrailer + 8, 8);
    m_top_object_offset = _get_uint_val(m_ptrailer + 16, 8);
    const uint64_t table = _get_uint_val(m_ptrailer + 24, 8);
    if (m_offset_table_offset_size < 1 || m_offset_table_offset_size > 8 || m_object_ref_size < 1 || m_object_ref_size > 8 ||
        m_num_objects == 0 || m_num_objects > 200000 || m_top_object_offset >= m_num_objects ||
        table < 9 || table > length - 32 || m_num_objects > (length - 32 - table) / m_offset_table_offset_size) return false;
    m_poffset_table = bytes + static_cast<size_t>(table);
    for (uint64_t index = 0; index < m_num_objects; ++index) {
        const uint64_t offset = _get_uint_val(m_poffset_table + index * m_offset_table_offset_size, m_offset_table_offset_size);
        if (offset < 8 || offset >= table) return false;
    }
    const uint64_t root = _get_uint_val(m_poffset_table + m_top_object_offset * m_offset_table_offset_size, m_offset_table_offset_size);
    const char* cursor = bytes + static_cast<size_t>(root);
    if (_read_binary_value(cursor, value)) return true;
    value.clear();
    return false;
}

jpwriter::jpwriter()
{
	m_tab = "\t";
	m_line = "\n";
}

//////////////////////////////////////////////////////////////////////////
void jpwriter::write(const jvalue& pval, string& strdoc)
{
	m_tab = "";
	m_line = "";
	strdoc = _style_write(pval);
}

uint8_t jpwriter::_get_integer_length(int64_t value)
{
	if (value > 0 && value < (1 << 8)) {
		return 0;
	} else if (value > 0 && value < (1 << 16)) {
		return 1;
	} else if (value > 0 && value < ((int64_t)1 << 32)) {
		return 2;
	} else {
		return 3;
	}
}

void jpwriter::_byte_convert(uint8_t* v, size_t size)
{
	uint8_t tmp = 0;
	for (size_t i = 0, j = 0; i < (size / 2); i++) {
		tmp = v[i];
		j = (size - 1) - i;
		v[i] = v[j];
		v[j] = tmp;
	}
}

uint16_t jpwriter::_swap(uint16_t value)
{
	return ((((value) & 0xFF00) >> 8) | (((value) & 0x00FF) << 8));
}

uint32_t jpwriter::_swap(uint32_t value)
{
	return ((((value) & 0xFF000000) >> 24) |
		(((value) & 0x00FF0000) >> 8) |
		(((value) & 0x0000FF00) << 8) |
		(((value) & 0x000000FF) << 24));
}

uint64_t jpwriter::_swap(uint64_t value)
{
	return  ((((value) & 0xFF00000000000000ull) >> 56) |
		(((value) & 0x00FF000000000000ull) >> 40) |
		(((value) & 0x0000FF0000000000ull) >> 24) |
		(((value) & 0x000000FF00000000ull) >> 8) |
		(((value) & 0x00000000FF000000ull) << 8) |
		(((value) & 0x0000000000FF0000ull) << 24) |
		(((value) & 0x000000000000FF00ull) << 40) |
		(((value) & 0x00000000000000FFull) << 56));
}

float jpwriter::_swap(float value)
{
	_byte_convert((uint8_t*)&value, sizeof(value));
	return value;
}

double jpwriter::_swap(double value)
{
	_byte_convert((uint8_t*)&value, sizeof(value));
	return value;
}

uint8_t jpwriter::_get_integer_bytes(int64_t value)
{
	if (value > 0 && value < (1 << 8)) {
		return 1;
	} else if (value > 0 && value < (1 << 16)) {
		return 2;
	} else if (value > 0 && value < ((int64_t)1 << 32)) {
		return 4;
	} else {
		return 8;
	}
}

int jpwriter::_get_serialize_integer(uint8_t* data, uint8_t length, int64_t value)
{
	switch (length) {
	case 1:
		data[0] = (uint8_t)value;
		break;
	case 2:
		data[0] = (uint8_t)(value >> 8);
		data[1] = (uint8_t)value;
		break;
	case 4:
		data[0] = (uint8_t)(value >> 24);
		data[1] = (uint8_t)(value >> 16);
		data[2] = (uint8_t)(value >> 8);
		data[3] = (uint8_t)value;
		break;
	case 8:
		data[0] = (uint8_t)(value >> 56);
		data[1] = (uint8_t)(value >> 48);
		data[2] = (uint8_t)(value >> 40);
		data[3] = (uint8_t)(value >> 32);
		data[4] = (uint8_t)(value >> 24);
		data[5] = (uint8_t)(value >> 16);
		data[6] = (uint8_t)(value >> 8);
		data[7] = (uint8_t)value;
		break;
	default:
		return -1;
	}
	return length;
}

void jpwriter::write_to_binary(const jvalue& pval, string& strdoc)
{
	strdoc.clear();

	vector<bplist_object> array_objects;
	vector<uint64_t> array_offset_indexes;
	_write_value_to_binary(pval, array_objects, array_offset_indexes);

	//check object ref size
	uint8_t object_ref_size = 1;
	uint64_t offset_table_size = array_offset_indexes.size();
	if (offset_table_size < (1 << 8)) {
		object_ref_size = 1;
	} else  if (offset_table_size < (1 << 16)) {
		object_ref_size = 2;
	} else if (offset_table_size < ((int64_t)1 << 32)) {
		object_ref_size = 4;
	} else {
		object_ref_size = 8;
	}

	//rebuild dictionary and array object data ad build address
	uint64_t start_address = 0x08;
	vector<uint64_t> array_offset_addresses;
	for (size_t i = 0; i < array_objects.size(); i++) {

		//rebuild dictionary and array object data
		bplist_object& object = array_objects[i];
		if (jpreader::NS_DICTIONARY == object.type || jpreader::NS_ARRAY == object.type) {

			object.data.clear();
			if (jpreader::NS_ARRAY == object.type) {
				_serialize_object_size(object.data, jpreader::NS_ARRAY, object.indexes.size());
			} else if (jpreader::NS_DICTIONARY == object.type) {
				_serialize_object_size(object.data, jpreader::NS_DICTIONARY, (object.indexes.size() / 2));
			}
			for (size_t j = 0; j < object.indexes.size(); j++) {
				if (1 == object_ref_size) {
					uint8_t index = (uint8_t)object.indexes[j];
					object.data.append((const char*)&index, sizeof(index));
				} else if (2 == object_ref_size) {
					uint16_t index = _swap((uint16_t)object.indexes[j]);
					object.data.append((const char*)&index, sizeof(index));
				} else if (4 == object_ref_size) {
					uint32_t index = _swap((uint32_t)object.indexes[j]);
					object.data.append((const char*)&index, sizeof(index));
				} else {
					uint64_t index = _swap((uint64_t)object.indexes[j]);
					object.data.append((const char*)&index, sizeof(index));
				}
			}

		}

		//build offset table address
		array_offset_addresses.push_back(start_address);
		start_address += object.data.size();
	}

	//header
	strdoc.append("bplist00", 8);

	//objects
	for (size_t i = 0; i < array_objects.size(); i++) {
		strdoc.append(array_objects[i].data);
	}

	uint64_t offset_table_start = strdoc.size();

	//offset table
	uint8_t offset_table_offset_size = 1;
	if (start_address < (1 << 8)) {
		offset_table_offset_size = 1;

		uint8_t root = (uint8_t)array_offset_addresses[(size_t)array_offset_indexes.back()];
		strdoc.append((const char*)&root, sizeof(root));

		for (size_t i = 0; i < array_offset_indexes.size() - 1; i++) {
			uint8_t index = (uint8_t)array_offset_addresses[(size_t)array_offset_indexes[i]];
			strdoc.append((const char*)&index, sizeof(index));
		}

	} else if (start_address < (1 << 16)) {
		offset_table_offset_size = 2;

		uint16_t root = _swap((uint16_t)array_offset_addresses[(size_t)array_offset_indexes.back()]);
		strdoc.append((const char*)&root, sizeof(root));

		for (size_t i = 0; i < array_offset_indexes.size() - 1; i++) {
			uint16_t index = _swap((uint16_t)array_offset_addresses[(size_t)array_offset_indexes[i]]);
			strdoc.append((const char*)&index, sizeof(index));
		}

	} else if (start_address < ((int64_t)1 << 32)) {
		offset_table_offset_size = 4;

		uint32_t root = _swap((uint32_t)array_offset_addresses[(size_t)array_offset_indexes.back()]);
		strdoc.append((const char*)&root, sizeof(root));

		for (size_t i = 0; i < array_offset_indexes.size() - 1; i++) {
			uint32_t index = _swap((uint32_t)array_offset_addresses[(size_t)array_offset_indexes[i]]);
			strdoc.append((const char*)&index, sizeof(index));
		}
	} else {
		offset_table_offset_size = 8;

		uint64_t root = _swap((uint64_t)array_offset_addresses[(size_t)array_offset_indexes.back()]);
		strdoc.append((const char*)&root, sizeof(root));

		for (size_t i = 0; i < array_offset_indexes.size() - 1; i++) {
			uint64_t index = _swap((uint64_t)array_offset_addresses[(size_t)array_offset_indexes[i]]);
			strdoc.append((const char*)&index, sizeof(index));
		}
	}

	//tailer
	strdoc.append(6, '\0');

	uint8_t val[2] = { 0 };
	val[0] = offset_table_offset_size;
	val[1] = object_ref_size;

	strdoc.append((const char*)val, 2);

	uint64_t num_objects = array_objects.size();
	num_objects = _swap(num_objects);
	strdoc.append((const char*)&num_objects, sizeof(uint64_t));

	uint64_t top_object_offset = 0;
	top_object_offset = _swap(top_object_offset);
	strdoc.append((const char*)&top_object_offset, sizeof(uint64_t));

	offset_table_start = _swap(offset_table_start);
	strdoc.append((const char*)&offset_table_start, sizeof(uint64_t));
}

void jpwriter::_serialize_object_size(string& data, jpreader::bplist_object_type object_type, int64_t object_size)
{
	if (jpreader::NS_NUMBER_INT != object_type) {
		if (object_size < 15) {
			uint8_t type = (uint8_t)(object_type | object_size);
			data.append((const char*)&type, sizeof(type));
			return;
		} else {
			uint8_t type = object_type | 0x0F;
			data.append((const char*)&type, sizeof(type));
		}
	}

	uint8_t value[9] = { 0 };
	value[0] = jpreader::NS_NUMBER_INT | _get_integer_length(object_size);

	uint8_t length = _get_integer_bytes(object_size);
	_get_serialize_integer(value + 1, length, object_size);
	data.append((const char*)value, length + 1);
}

bool jpwriter::_contains_unicode_char(const char* str, size_t len)
{
	for (size_t i = 0; i < len; i++) {
		uint8_t c = (uint8_t)str[i];
		if (c & 0x80) {
			return true;
		}
	}
	return false;
}

bool jpwriter::_utf8_to_utf16(const char* utf8, size_t len, string& utf16)
{
	size_t i = 0;
	while (i < len) {
		uint32_t codepoint = 0;
		size_t extra_bytes = 0;
		uint8_t first = (uint8_t)utf8[i];
		if (first <= 0x7F) {
			codepoint = first;
			extra_bytes = 0;
		} else if ((first & 0xE0) == 0xC0) {
			codepoint = first & 0x1F;
			extra_bytes = 1;
		} else if ((first & 0xF0) == 0xE0) {
			codepoint = first & 0x0F;
			extra_bytes = 2;
		} else if ((first & 0xF8) == 0xF0) {
			codepoint = first & 0x07;
			extra_bytes = 3;
		} else {
			return false;
		}

		if (i + extra_bytes >= len) {
			return false;
		}

		for (size_t j = 1; j <= extra_bytes; ++j) {
			codepoint = (codepoint << 6) | (((uint8_t)utf8[i + j]) & 0x3F);
		}

		uint16_t uc = 0;
		if (codepoint <= 0xFFFF) {
			uc = _swap(static_cast<uint16_t>(codepoint));
			utf16.append((const char*)&uc, sizeof(uc));
		} else {
			codepoint -= 0x10000;
			uc = _swap(static_cast<uint16_t>(0xD800 + (codepoint >> 10)));
			utf16.append((const char*)&uc, sizeof(uc));
			uc = _swap(static_cast<uint16_t>(0xDC00 + (codepoint & 0x3FF)));
			utf16.append((const char*)&uc, sizeof(uc));
		}

		i += extra_bytes + 1;
	}

	return true;
}

int64_t jpwriter::_write_value_to_binary(const jvalue& pval, vector<bplist_object>& array_objects, vector<uint64_t>& array_offset_indexes)
{
	bplist_object object;
	if (pval.is_object()) {
		object.type = jpreader::NS_DICTIONARY;
		vector<string> keys;
		pval.get_keys(keys);
		size_t obj_size = keys.size();
		_serialize_object_size(object.data, jpreader::NS_DICTIONARY, obj_size);

		vector<int64_t> key_indexes;
		vector<int64_t> val_indexes;
		for (size_t i = 0; i < obj_size; i++) {
			int64_t key_index = _write_value_to_binary(keys[i].c_str(), array_objects, array_offset_indexes);
			int64_t val_index = _write_value_to_binary(pval[keys[i].c_str()], array_objects, array_offset_indexes);
			key_indexes.push_back(key_index);
			val_indexes.push_back(val_index);
		}

		for (size_t i = 0; i < key_indexes.size(); i++) {
			int64_t& index = key_indexes[i];
			object.indexes.push_back(index);
			object.data.append((const char*)&index, sizeof(index));
		}
		for (size_t i = 0; i < val_indexes.size(); i++) {
			int64_t& index = val_indexes[i];
			object.indexes.push_back(index);
			object.data.append((const char*)&index, sizeof(index));
		}

	} else if (pval.is_array()) {
		object.type = jpreader::NS_ARRAY;
		size_t obj_size = pval.size();
		_serialize_object_size(object.data, jpreader::NS_ARRAY, obj_size);
		for (size_t i = 0; i < obj_size; i++) {
			int64_t index = _write_value_to_binary(pval[i], array_objects, array_offset_indexes);
			object.indexes.push_back(index);
			object.data.append((const char*)&index, sizeof(index));
		}
	} else if (pval.is_date()) {
		object.type = jpreader::NS_DATE;
		double dval = _swap((double)(pval.as_date() - 978307200));
		uint8_t type = jpreader::NS_DATE | 3;
		object.data.append((const char*)&type, 1);
		object.data.append((const char*)&dval, sizeof(double));
	} else if (pval.is_data()) {
		object.type = jpreader::NS_DATA;
		string strData = pval.as_data();
		size_t obj_size = strData.size();
		_serialize_object_size(object.data, jpreader::NS_DATA, obj_size);
		object.data.append(strData.data(), obj_size);
	} else if (pval.is_string()) { //must behind date and data
		const char* szVal = pval.as_cstr();
		size_t obj_size = strlen(szVal);
		bool unicode = false;
		if (_contains_unicode_char(szVal, obj_size)) {
			string utf16;
			if (_utf8_to_utf16(szVal, obj_size, utf16)) {
				unicode = true;
				object.type = jpreader::NS_STRING_UNICODE;
				obj_size = utf16.size() / 2;
				_serialize_object_size(object.data, jpreader::NS_STRING_UNICODE, obj_size);
				object.data.append(utf16);
			}
		}
		if (!unicode) {
			object.type = jpreader::NS_STRING_ASCII;
			_serialize_object_size(object.data, jpreader::NS_STRING_ASCII, obj_size);
			object.data.append((const char*)szVal, obj_size);
		}
	} else if (pval.is_bool()) {
		object.type = jpreader::BPLIST_NULL;
		uint8_t type = jpreader::BPLIST_NULL | (pval.as_bool() ? jpreader::NS_NUMBER_TRUE : jpreader::NS_NUMBER_FALSE);
		object.data.append((const char*)&type, 1);
	} else if (pval.is_int()) {
		object.type = jpreader::NS_NUMBER_INT;
		_serialize_object_size(object.data, jpreader::NS_NUMBER_INT, pval.as_int64());
	} else if (pval.is_double()) {
		object.type = jpreader::NS_NUMBER_REAL;
		double dval = _swap(pval.as_double());
		uint8_t type = jpreader::NS_NUMBER_REAL | 3;
		object.data.append((const char*)&type, 1);
		object.data.append((const char*)&dval, sizeof(double));
	} else if (pval.is_null()) {
		object.type = jpreader::BPLIST_NULL;
		object.data.append(1, '\0');
	} else {
		assert(0);
		object.type = jpreader::BPLIST_NULL;
		object.data.append(1, '\0');
	}

	int64_t offset_index = -1;
	size_t object_size = object.data.size();
	for (size_t i = 0; i < array_objects.size(); i++) {
		if (array_objects[i].type == object.type) {
			if (array_objects[i].data.size() == object_size) {
				if (0 == ::memcmp(array_objects[i].data.data(), object.data.data(), object_size)) {
					offset_index = i;
				}
			}
		}
	}

	if (offset_index < 0) {
		array_objects.push_back(object);
		offset_index = array_objects.size() - 1;
		array_offset_indexes.push_back(offset_index);
	}

	return offset_index + 1;
}

const string& jpwriter::style_write(const jvalue& pval)
{
	m_tab = "\t";
	m_line = "\n";
	return _style_write(pval);
}

const string& jpwriter::_style_write(const jvalue& pval)
{
	m_indent = "";
	m_strdoc = "";
	m_strdoc += "<?xml version=\"1.0\" encoding=\"UTF-8\"?>" + m_line;
	m_strdoc += "<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">" + m_line;
	m_strdoc += "<plist version=\"1.0\">" + m_line;
	_style_write_value(pval);
	m_strdoc += "</plist>" + m_line;
	return m_strdoc;
}

void jpwriter::_style_write_value(const jvalue& pval)
{
	if (pval.is_object()) {
		vector<string> keys;
		pval.get_keys(keys);
		if (!keys.empty()) {
			m_strdoc += m_indent + "<dict>" + m_line;
			m_indent += m_tab;
			for (size_t i = 0; i < keys.size(); i++) {
				string strkey = keys[i];
				_xml_escape(strkey);
				m_strdoc += m_indent + "<key>";
				m_strdoc += strkey;
				m_strdoc += "</key>" + m_line;
				_style_write_value(pval[keys[i].c_str()]);
			}
			if (!m_indent.empty()) {
				m_indent.resize(m_indent.size() - 1);
			}
			m_strdoc += m_indent + "</dict>" + m_line;
		} else {
			m_strdoc += m_indent + "<dict/>" + m_line;
		}
	} else if (pval.is_array()) {
		if (pval.size() > 0) {
			m_strdoc += m_indent + "<array>" + m_line;
			m_indent += m_tab;
			for (size_t i = 0; i < pval.size(); i++) {
				_style_write_value(pval[i]);
			}
			if (!m_indent.empty()) {
				m_indent.resize(m_indent.size() - 1);
			}
			m_strdoc += m_indent + "</array>" + m_line;
		} else {
			m_strdoc += m_indent + "<array/>" + m_line;
		}
	} else if (pval.is_date()) {
		m_strdoc += m_indent + "<date>";
		m_strdoc += jwriter::d2s(pval.as_date());
		m_strdoc += "</date>" + m_line;
	} else if (pval.is_data()) {
		m_strdoc += m_indent + "<data>" + m_line;
		m_strdoc += m_indent;
		jbase64 b64;
		string strdata = pval.as_data();
		m_strdoc += b64.encode(strdata.data(), (int32_t)strdata.size());
		m_strdoc += m_line;
		m_strdoc += m_indent + "</data>" + m_line;
	} else if (pval.is_string()) {
		if (pval.is_date_string()) {
			m_strdoc += m_indent + "<date>";
			m_strdoc += pval.as_string().c_str() + 5;
			m_strdoc += "</date>" + m_line;
		} else if (pval.is_data_string()) {
			m_strdoc += m_indent + "<data>" + m_line;
			m_strdoc += m_indent;
			m_strdoc += pval.as_string().c_str() + 5;
			m_strdoc += m_line;
			m_strdoc += m_indent + "</data>" + m_line;
		} else {
			string strval = pval.as_cstr();
			_xml_escape(strval);
			m_strdoc += m_indent + "<string>";
			m_strdoc += strval;
			m_strdoc += "</string>" + m_line;
		}
	} else if (pval.is_bool()) {
		m_strdoc += m_indent + (pval.as_bool() ? "<true/>" : "<false/>") + m_line;
	} else if (pval.is_int()) {
		m_strdoc += m_indent + "<integer>";
		char temp[32];
		snprintf(temp, 32, "%" PRId64, pval.as_int64());
		m_strdoc += temp;
		m_strdoc += "</integer>" + m_line;
	} else if (pval.is_double()) {
		m_strdoc += m_indent + "<real>";
		double v = pval.as_double();
		if (numeric_limits<double>::infinity() == v) {
			m_strdoc += "+infinity";
		} else {
			char temp[32];
			if (floor(v) == v) {
				snprintf(temp, sizeof(temp), "%" PRId64, (int64_t)v);
			} else {
				snprintf(temp, sizeof(temp), "%.15lf", v);
			}
			m_strdoc += temp;
		}
		m_strdoc += "</real>" + m_line;
	} else {
		m_strdoc += m_indent + "<integer>0</integer>" + m_line;
	}
}

void jpwriter::_xml_escape(string& str)
{
	_string_replace(str, "&", "&amp;");
	_string_replace(str, "<", "&lt;");
	//_string_replace(str, ">", "&gt;");	//optional
	//_string_replace(str, "'", "&apos;");	//optional
	//_string_replace(str, "\"", "&quot;");	//optional
}

string& jpwriter::_string_replace(string& context, const string& from, const string& to)
{
	size_t query = 0;
	size_t found = 0;
	while ((found = context.find(from, query)) != string::npos) {
		context.replace(found, from.size(), to);
		query = found + to.size();
	}
	return context;
}
