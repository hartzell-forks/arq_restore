//
//  OpenSSLCryptoKey.m
//  Arq
//
//  Created by Stefan Reitshamer on 10/8/12.
//  Copyright (c) 2012 Stefan Reitshamer. All rights reserved.
//

#ifdef USE_OPENSSL


#import "OpenSSLCryptoKey.h"
#import "OpenSSL.h"
#import "CryptoKey.h"


#define ITERATIONS (1000)
#define KEYLEN (48)

#pragma GCC diagnostic ignored "-Wdeprecated-declarations"

@implementation OpenSSLCryptoKey

- (id)initWithPassword:(NSString *)thePassword salt:(NSData *)theSalt error:(NSError **)error {
    if (self = [super init]) {
        if (![OpenSSL initializeSSL:error]) {
            [self release];
            return nil;
        }
        if (theSalt != nil && [theSalt length] != 8) {
            SETNSERROR([CryptoKey errorDomain], -1, @"salt must be 8 bytes or nil");
            [self release];
            return nil;
        }
        cipher = EVP_aes_256_cbc();
        if (cipher == NULL) {
            SETNSERROR([CryptoKey errorDomain], -1, @"cipher not found!");
            [self release];
            return nil;
        }
        const char *cPassword = [thePassword UTF8String];
        unsigned char *cSaltCopy = NULL;
        if (theSalt != nil) {
            cSaltCopy = (unsigned char *)malloc([theSalt length]);
            memcpy(cSaltCopy, [theSalt bytes], [theSalt length]);
        } else {
            HSLogWarn(@"NULL salt value for CryptoKey");
        }
        unsigned char buf[KEYLEN];
        memset(buf, 0, KEYLEN);
        if (PKCS5_PBKDF2_HMAC_SHA1(cPassword, (int)strlen(cPassword), cSaltCopy, (int)[theSalt length], ITERATIONS, KEYLEN, buf) == 0) {
            SETNSERROR([CryptoKey errorDomain], -1, @"PKCS5_PBKDF2_HMAC_SHA1 failed");
            if (cSaltCopy != NULL) {
                free(cSaltCopy);
            }
            [self release];
            return nil;
        }
        evpKey[0] = 0;
        int keySize = EVP_BytesToKey(cipher, EVP_sha1(), cSaltCopy, buf, KEYLEN, ITERATIONS, evpKey, iv);
        if (cSaltCopy != NULL) {
            free(cSaltCopy);
        }
        if (keySize == 0) {
            SETNSERROR([CryptoKey errorDomain], -1, @"EVP_BytesToKey: %@", [OpenSSL errorMessage]);
            [self release];
            return nil;
        }
        if (keySize != 32) {
            SETNSERROR([CryptoKey errorDomain], -1, @"invalid key length -- should be 32 bytes");
            [self release];
            return nil;
        }
    }
    return self;
}
- (id)initLegacyWithPassword:(NSString *)thePassword error:(NSError **)error {
    if (self = [super init]) {
        if (![OpenSSL initializeSSL:error]) {
            [self release];
            return nil;
        }
        
        cipher = EVP_aes_256_cbc();
        evpKey[0] = 0;
        NSData *passwordData = [thePassword dataUsingEncoding:NSUTF8StringEncoding];
        int keySize = EVP_BytesToKey(cipher, EVP_md5(), NULL, [passwordData bytes], (int)[passwordData length], 1, evpKey, iv);
        if (keySize == 0) {
            SETNSERROR([CryptoKey errorDomain], -1, @"EVP_BytesToKey: %@", [OpenSSL errorMessage]);
            [self release];
            return nil;
        }
        if (keySize != 32) {
            SETNSERROR([CryptoKey errorDomain], -1, @"invalid key length -- should be 32 bytes");
            [self release];
            return nil;
        }
    }
    return self;
}
- (void)dealloc {
    [super dealloc];
}

- (NSData *)encrypt:(NSData *)plainData error:(NSError **)error {
    if ([plainData length] == 0) {
        return [NSData data];
    }
    EVP_CIPHER_CTX cipherContext;
    EVP_CIPHER_CTX_init(&cipherContext);
    if (!EVP_EncryptInit(&cipherContext, cipher, evpKey, iv)) {
        SETNSERROR([CryptoKey errorDomain], -1, @"EVP_EncryptInit: %@", [OpenSSL errorMessage]);
        EVP_CIPHER_CTX_cleanup(&cipherContext);
        return nil;
    }
    
    // Need room for data + cipher block size - 1.
    unsigned char *outbuf = (unsigned char *)malloc([plainData length] + EVP_CIPHER_CTX_block_size(&cipherContext) - 1);
    
    int outlen = 0;
    if (!EVP_EncryptUpdate(&cipherContext, outbuf, &outlen, [plainData bytes], (int)[plainData length])) {
        SETNSERROR([CryptoKey errorDomain], -1, @"EVP_EncryptUpdate: %@",  [OpenSSL errorMessage]);
        free(outbuf);
        EVP_CIPHER_CTX_cleanup(&cipherContext);
        return nil;
    }
    
    int extralen = 0;
    if (!EVP_EncryptFinal(&cipherContext, outbuf + outlen, &extralen)) {
        SETNSERROR([CryptoKey errorDomain], -1, @"EVP_EncryptFinal: %@",  [OpenSSL errorMessage]);
        free(outbuf);
        EVP_CIPHER_CTX_cleanup(&cipherContext);
        return nil;
    }
    EVP_CIPHER_CTX_cleanup(&cipherContext);
    
    NSData *ret = [[[NSData alloc] initWithBytesNoCopy:outbuf length:(outlen + extralen)] autorelease];
    return ret;
}
- (NSData *)decrypt:(NSData *)encrypted error:(NSError **)error {
    if (encrypted == nil) {
        SETNSERROR([CryptoKey errorDomain], -1, @"decrypt: nil input NSData");
        return nil;
    }
    if ([encrypted length] == 0) {
        return [NSData data];
    }
    
    int inlen = (int)[encrypted length];
    unsigned char *input = (unsigned char *)[encrypted bytes];
    
    EVP_CIPHER_CTX cipherContext;
    EVP_CIPHER_CTX_init(&cipherContext);
    if (!EVP_DecryptInit(&cipherContext, cipher, evpKey, iv)) {
        SETNSERROR([CryptoKey errorDomain], -1, @"EVP_DecryptInit: %@", [OpenSSL errorMessage]);
        EVP_CIPHER_CTX_cleanup(&cipherContext);
        return nil;
    }
    
    unsigned char *outbuf = (unsigned char *)malloc(inlen + EVP_CIPHER_CTX_block_size(&cipherContext));
    
    int outlen = 0;
    if (!EVP_DecryptUpdate(&cipherContext, outbuf, &outlen, input, inlen)) {
        SETNSERROR([CryptoKey errorDomain], -1, @"EVP_DecryptUpdate: %@", [OpenSSL errorMessage]);
        free(outbuf);
        EVP_CIPHER_CTX_cleanup(&cipherContext);
        return nil;
    }
    
    int extralen = 0;
    if (!EVP_DecryptFinal(&cipherContext, outbuf + outlen, &extralen)) {
        SETNSERROR([CryptoKey errorDomain], -1, @"EVP_DecryptFinal: %@", [OpenSSL errorMessage]);
        free(outbuf);
        EVP_CIPHER_CTX_cleanup(&cipherContext);
        return nil;
    }
    
    EVP_CIPHER_CTX_cleanup(&cipherContext);
    NSData *ret = [[[NSData alloc] initWithBytesNoCopy:outbuf length:(outlen + extralen)] autorelease];
    return ret;
}
@end

#endif