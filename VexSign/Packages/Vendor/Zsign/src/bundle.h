#pragma once
#include "common.h"
#include "json.h"
#include "openssl.h"
#include <vector>
#include <map>

class ZBundle
{
public:
	ZBundle();

public:
	bool SignFolder(ZSignAsset* pSignAsset,
					const string& strFolder,
					const string& strBundleId,
					const string& strBundleVersion,
					const string& strDisplayName,
					const vector<string>& arrDylibFiles,
					bool bForce,
					bool bWeakInject,
					bool bEnableCache,
					bool excludeProvisioning);

private:
	bool SignNode(jvalue& jvNode);
	void GetNodeChangedFiles(jvalue& jvNode, bool dontGenerateEmbeddedMobileProvision);
	void GetChangedFiles(jvalue& jvNode, vector<string>& arrChangedFiles);
	bool ModifyPluginsBundleId(const string& strOldBundleId, const string& strNewBundleId);
	bool ModifyBundleInfo(const string& strBundleId, const string& strBundleVersion, const string& strDisplayName);

private:
	bool FindAppFolder(const string& strFolder, string& strAppFolder);
	bool GetObjectsToSign(const string& strFolder, jvalue& jvInfo);
	bool GetSignFolderInfo(const string& strFolder, jvalue& jvNode, bool bGetName = false);

private:
	bool GenerateCodeResources(const string& strFolder, jvalue& jvCodeRes);

private:
	bool			m_bForceSign;
	bool			m_bWeakInject;
	ZSignAsset*		m_pSignAsset;
	vector<string>	m_arrInjectDylibs;

public:
	string			m_strAppFolder;
	string signFailedFiles;
	// Nested bundles (app extensions, watch apps) that are signed with a provisioning
	// profile of their own, keyed by the bundle identifier the nested bundle carries when
	// it is signed. Empty by default, which leaves every nested bundle on the outer asset
	// exactly as before. The assets are owned by the caller and must outlive SignFolder.
	map<string, ZSignAsset*>	m_mapNestedAssets;
	// Whether a nested bundle signed with its own asset also carries that profile.
	bool						m_bEmbedNestedProvisions = true;
};
