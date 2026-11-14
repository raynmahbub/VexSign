#include "base64.h"
#include <string.h>

#define B0(a) (a & 0xFF)
#define B1(a) (a >> 8 & 0xFF)
#define B2(a) (a >> 16 & 0xFF)
#define B3(a) (a >> 24 & 0xFF)

jbase64::jbase64()
{
}

jbase64::~jbase64()
{
	if (!m_array_encodes.empty()) {
		for (size_t i = 0; i < m_array_encodes.size(); i++) {
			delete[] m_array_encodes[i];
		}
		m_array_encodes.clear();
	}

	if (!m_array_decodes.empty()) {
		for (size_t i = 0; i < m_array_decodes.size(); i++) {
			delete[] m_array_decodes[i];
		}
		m_array_decodes.clear();
	}
}

char jbase64::get_b64_char(int index)
{
	static const char table[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
	if (index >= 0 && index < 64) {
		return table[index];
	}
	return '=';
}

int jbase64::get_b64_index(char ch)
{
	int index = -1;
	if (ch >= 'A' && ch <= 'Z') {
		index = ch - 'A';
	} else if (ch >= 'a' && ch <= 'z') {
		index = ch - 'a' + 26;
	} else if (ch >= '0' && ch <= '9') {
		index = ch - '0' + 52;
	} else if (ch == '+') {
		index = 62;
	} else if (ch == '/') {
		index = 63;
	}
	return index;
}

const char* jbase64::encode(const char* src, int src_len)
{
	if (0 == src_len) {
		src_len = (int)strlen(src);
	}

	if (src_len <= 0) {
		return "";
	}

	char* enc = new char[src_len * 3 + 128];
	m_array_encodes.push_back(enc);

	int i = 0;
	char* p64 = enc;
	unsigned char* pcursor = (unsigned char*)src;
	for (i = 0; i < src_len - 3; i += 3) {
        // Consume exactly three bytes. A machine-word load is both unaligned
        // and out of bounds at the end of a SHA1/SHA256 buffer on 64-bit hosts.
        unsigned long temp = pcursor[0] | (static_cast<unsigned long>(pcursor[1]) << 8) | (static_cast<unsigned long>(pcursor[2]) << 16);
		int b0 = get_b64_char((B0(temp) >> 2) & 0x3F);
		int b1 = get_b64_char((B0(temp) << 6 >> 2 | B1(temp) >> 4) & 0x3F);
		int b2 = get_b64_char((B1(temp) << 4 >> 2 | B2(temp) >> 6) & 0x3F);
		int b3 = get_b64_char((B2(temp) << 2 >> 2) & 0x3F);
        p64[0] = b0; p64[1] = b1; p64[2] = b2; p64[3] = b3;
		p64 += 4;
		pcursor += 3;
	}

	if (i < src_len) {
		int rest = src_len - i;
		unsigned long temp = 0;
		for (int j = 0; j < rest; ++j) {
			*(((unsigned char*)&temp) + j) = *pcursor++;
		}
		p64[0] = get_b64_char((B0(temp) >> 2) & 0x3F);
		p64[1] = get_b64_char((B0(temp) << 6 >> 2 | B1(temp) >> 4) & 0x3F);
		p64[2] = rest > 1 ? get_b64_char((B1(temp) << 4 >> 2 | B2(temp) >> 6) & 0x3F) : '=';
		p64[3] = rest > 2 ? get_b64_char((B2(temp) << 2 >> 2) & 0x3F) : '=';
		p64 += 4;
	}
	*p64 = '\0';
	return enc;
}

const char* jbase64::encode(const string& input)
{
	return encode(input.data(), (int)input.size());
}

const char* jbase64::decode(const char* src, int src_len, int* pdecode_len)
{
    if (pdecode_len) *pdecode_len = 0;
    if (!src || src_len < 0) return "";
	if (0 == src_len) {
		src_len = (int)strlen(src);
	}

	if (src_len <= 0) {
		return "";
	}

    if (src_len % 4) return "";
    int padding = src[src_len - 1] == '=' ? (src[src_len - 2] == '=' ? 2 : 1) : 0;
    for (int index = 0; index < src_len - padding; ++index) if (get_b64_index(src[index]) < 0) return "";
    if ((padding == 1 && (get_b64_index(src[src_len - 2]) & 3)) ||
        (padding == 2 && (get_b64_index(src[src_len - 3]) & 15))) return "";
    char* dec = new char[src_len];
	m_array_decodes.push_back(dec);

	int i = 0;
	char* pbuf = dec;
	unsigned char* psrc = (unsigned char*)src;
	for (i = 0; i < src_len - 4; i += 4) {
        unsigned long temp = psrc[0] | (static_cast<unsigned long>(psrc[1]) << 8) |
            (static_cast<unsigned long>(psrc[2]) << 16) | (static_cast<unsigned long>(psrc[3]) << 24);
		int b0 = (get_b64_index((char)B0(temp)) << 2 | get_b64_index((char)B1(temp)) << 2 >> 6) & 0xFF;
		int b1 = (get_b64_index((char)B1(temp)) << 4 | get_b64_index((char)B2(temp)) << 2 >> 4) & 0xFF;
		int b2 = (get_b64_index((char)B2(temp)) << 6 | get_b64_index((char)B3(temp)) << 2 >> 2) & 0xFF;
        pbuf[0] = b0; pbuf[1] = b1; pbuf[2] = b2;
		psrc += 4;
		pbuf += 3;
	}

    if (i < src_len) {
        const int a = get_b64_index(src[i]), b = get_b64_index(src[i + 1]);
        const int c = padding >= 2 ? 0 : get_b64_index(src[i + 2]);
        const int d = padding >= 1 ? 0 : get_b64_index(src[i + 3]);
        *pbuf++ = static_cast<char>((a << 2) | (b >> 4));
        if (padding < 2) *pbuf++ = static_cast<char>((b << 4) | (c >> 2));
        if (padding < 1) *pbuf++ = static_cast<char>((c << 6) | d);
    }
	*pbuf = '\0';

	if (NULL != pdecode_len) {
		*pdecode_len = (int)(pbuf - dec);
	}

	return dec;
}

const char* jbase64::decode(const char* src, string& output)
{
	output.clear();
	int dec_len = 0;
	const char* p = decode(src, 0, &dec_len);
	output.append(p, dec_len);
	return output.data();
}
