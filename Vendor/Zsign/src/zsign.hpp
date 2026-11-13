//
//  zsign.hpp
//  feather
//
//  Created by HAHALOSAH on 5/22/24.
//

#ifndef zsign_hpp
#define zsign_hpp

#include <stdio.h>
#import <Foundation/Foundation.h>

#ifdef __cplusplus
extern "C" {
#endif

bool CheckIfSigned(NSString *filePath);
bool InjectDyLib(NSString *filePath, NSString *dylibPath, bool weakInject);
bool UninstallDylibs(NSString *filePath, NSArray<NSString *> *dylibPathsArray);
NSArray<NSString *> *ListDylibs(NSString *filePath);
bool ChangeDylibPath(NSString *filePath, NSString *oldPath, NSString *newPath);

int zsign(
	NSString *app,
	NSString *prov,
	NSString *key,
	NSString *pass,
	NSString *entitlement,
	NSString *bundleid,
	NSString *displayname,
	NSString *bundleversion,
	bool adhoc,
	bool dontGenerateEmbeddedMobileProvision,
	void(^completionHandler)(BOOL success, NSError *error)
);

/// The same as `zsign`, with provisioning profiles for individual nested bundles.
/// `nestedProvisions` maps the bundle identifier of an app extension or watch app to the
/// path of the profile it is signed with. A nested bundle that is not listed is signed
/// with the outer profile, as `zsign` does. Nil or empty behaves exactly like `zsign`.
int zsignWithNestedProvisions(
	NSString *app,
	NSString *prov,
	NSString *key,
	NSString *pass,
	NSString *entitlement,
	NSString *bundleid,
	NSString *displayname,
	NSString *bundleversion,
	bool adhoc,
	bool dontGenerateEmbeddedMobileProvision,
	NSDictionary<NSString *, NSString *> *nestedProvisions,
	void(^completionHandler)(BOOL success, NSError *error)
);

int checkCert(
	NSString *prov,
	NSString *key,
	NSString *pass,
	void(^completionHandler)(int status, NSDate* expirationDate, NSString *error)
);

#ifdef __cplusplus
}
#endif

#endif /* zsign_hpp */
