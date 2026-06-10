#!/usr/bin/env python3
"""
Upload a Civ 5 mod (.civ5mod) to the Steam Workshop from macOS.

Civ 5 uses the LEGACY Remote Storage Workshop (ISteamRemoteStorage::
PublishWorkshopFile), which steamcmd's workshop_build_item cannot touch.
This script does what ModBuddy does on Windows: writes the package and a
preview image into Steam Cloud under app 8930, then publishes them.

Requires: Steam client running and logged in to an account that owns Civ 5.

Usage:
  python3 workshop_upload.py publish <mod.civ5mod> <preview.jpg> "<title>" "<description>" [--public]
  python3 workshop_upload.py update  <published_file_id> <mod.civ5mod> "<changenote>"
  python3 workshop_upload.py quota
"""

import ctypes
import os
import sys
import time

APPID = 8930  # Sid Meier's Civilization V

STEAM_API_DYLIB = (
    "/Users/0xvitae/Library/Application Support/Steam/Steam.AppBundle/Steam/"
    "Contents/MacOS/Frameworks/Steam Helper.app/Contents/MacOS/libsteam_api.dylib"
)

# Steamworks constants
K_EWORKSHOP_FILE_TYPE_COMMUNITY = 0
VIS_PUBLIC, VIS_FRIENDS, VIS_PRIVATE = 0, 1, 2
# k_iClientRemoteStorageCallbacks = 1300
CB_PUBLISH_FILE_RESULT = 1309        # RemoteStoragePublishFileResult_t
CB_UPDATE_FILE_RESULT = 1316         # RemoteStorageUpdatePublishedFileResult_t

ERESULT = {
    1: "OK", 2: "Fail", 3: "NoConnection", 8: "InvalidParam", 9: "FileNotFound",
    10: "Busy", 15: "AccessDenied", 16: "Timeout", 21: "ServiceUnavailable",
    24: "InsufficientPrivilege (Workshop legal agreement not accepted? Limited account?)",
    25: "LimitExceeded (cloud quota or file size)",
}


class SteamParamStringArray(ctypes.Structure):
    _fields_ = [("strings", ctypes.POINTER(ctypes.c_char_p)), ("num", ctypes.c_int32)]


def load_api():
    os.environ["SteamAppId"] = str(APPID)
    os.environ["SteamGameId"] = str(APPID)
    lib = ctypes.CDLL(STEAM_API_DYLIB)

    lib.SteamAPI_InitFlat.restype = ctypes.c_int
    lib.SteamAPI_InitFlat.argtypes = [ctypes.c_char_p]
    lib.SteamAPI_SteamRemoteStorage_v016.restype = ctypes.c_void_p
    lib.SteamAPI_SteamUtils_v010.restype = ctypes.c_void_p

    lib.SteamAPI_ISteamRemoteStorage_FileWrite.restype = ctypes.c_bool
    lib.SteamAPI_ISteamRemoteStorage_FileWrite.argtypes = [
        ctypes.c_void_p, ctypes.c_char_p, ctypes.c_void_p, ctypes.c_int32]
    lib.SteamAPI_ISteamRemoteStorage_GetQuota.restype = ctypes.c_bool
    lib.SteamAPI_ISteamRemoteStorage_GetQuota.argtypes = [
        ctypes.c_void_p, ctypes.POINTER(ctypes.c_uint64), ctypes.POINTER(ctypes.c_uint64)]
    lib.SteamAPI_ISteamRemoteStorage_PublishWorkshopFile.restype = ctypes.c_uint64
    lib.SteamAPI_ISteamRemoteStorage_PublishWorkshopFile.argtypes = [
        ctypes.c_void_p, ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint32,
        ctypes.c_char_p, ctypes.c_char_p, ctypes.c_int,
        ctypes.POINTER(SteamParamStringArray), ctypes.c_int]
    # Update flow (for pushing new versions to an existing workshop item)
    lib.SteamAPI_ISteamRemoteStorage_CreatePublishedFileUpdateRequest.restype = ctypes.c_uint64
    lib.SteamAPI_ISteamRemoteStorage_CreatePublishedFileUpdateRequest.argtypes = [
        ctypes.c_void_p, ctypes.c_uint64]
    lib.SteamAPI_ISteamRemoteStorage_UpdatePublishedFileFile.restype = ctypes.c_bool
    lib.SteamAPI_ISteamRemoteStorage_UpdatePublishedFileFile.argtypes = [
        ctypes.c_void_p, ctypes.c_uint64, ctypes.c_char_p]
    lib.SteamAPI_ISteamRemoteStorage_UpdatePublishedFileSetChangeDescription.restype = ctypes.c_bool
    lib.SteamAPI_ISteamRemoteStorage_UpdatePublishedFileSetChangeDescription.argtypes = [
        ctypes.c_void_p, ctypes.c_uint64, ctypes.c_char_p]
    lib.SteamAPI_ISteamRemoteStorage_CommitPublishedFileUpdate.restype = ctypes.c_uint64
    lib.SteamAPI_ISteamRemoteStorage_CommitPublishedFileUpdate.argtypes = [
        ctypes.c_void_p, ctypes.c_uint64]

    lib.SteamAPI_ISteamUtils_IsAPICallCompleted.restype = ctypes.c_bool
    lib.SteamAPI_ISteamUtils_IsAPICallCompleted.argtypes = [
        ctypes.c_void_p, ctypes.c_uint64, ctypes.POINTER(ctypes.c_bool)]
    lib.SteamAPI_ISteamUtils_GetAPICallResult.restype = ctypes.c_bool
    lib.SteamAPI_ISteamUtils_GetAPICallResult.argtypes = [
        ctypes.c_void_p, ctypes.c_uint64, ctypes.c_void_p, ctypes.c_int,
        ctypes.c_int, ctypes.POINTER(ctypes.c_bool)]
    lib.SteamAPI_ISteamUtils_GetAPICallFailureReason.restype = ctypes.c_int
    lib.SteamAPI_ISteamUtils_GetAPICallFailureReason.argtypes = [ctypes.c_void_p, ctypes.c_uint64]

    err = ctypes.create_string_buffer(1024)
    res = lib.SteamAPI_InitFlat(err)
    if res != 0:
        sys.exit(f"SteamAPI init failed ({res}): {err.value.decode()} — is Steam running and logged in?")

    storage = lib.SteamAPI_SteamRemoteStorage_v016()
    utils = lib.SteamAPI_SteamUtils_v010()
    if not storage or not utils:
        sys.exit("Could not get Steam interfaces")
    return lib, storage, utils


def wait_call(lib, utils, call, expected_cb, bufsize=64):
    failed = ctypes.c_bool(False)
    deadline = time.time() + 300
    while time.time() < deadline:
        lib.SteamAPI_RunCallbacks()
        if lib.SteamAPI_ISteamUtils_IsAPICallCompleted(utils, call, ctypes.byref(failed)):
            buf = ctypes.create_string_buffer(bufsize)
            ok = lib.SteamAPI_ISteamUtils_GetAPICallResult(
                utils, call, buf, bufsize, expected_cb, ctypes.byref(failed))
            if not ok or failed.value:
                reason = lib.SteamAPI_ISteamUtils_GetAPICallFailureReason(utils, call)
                sys.exit(f"API call failed (failure reason {reason})")
            return buf.raw
        time.sleep(0.1)
    sys.exit("Timed out waiting for Steam (5 min)")


def parse_publish_result(raw):
    # struct (pack 4 on macOS): int32 eResult; uint64 publishedFileId; bool needsLegalAgreement
    eresult = int.from_bytes(raw[0:4], "little")
    file_id = int.from_bytes(raw[4:12], "little")
    needs_legal = raw[12] != 0
    return eresult, file_id, needs_legal


def cloud_write(lib, storage, cloud_name, local_path):
    data = open(local_path, "rb").read()
    ok = lib.SteamAPI_ISteamRemoteStorage_FileWrite(
        storage, cloud_name.encode(), data, len(data))
    print(f"  cloud write {cloud_name} ({len(data)} bytes): {'OK' if ok else 'FAILED'}")
    if not ok:
        sys.exit("FileWrite failed — check cloud quota (run: workshop_upload.py quota) "
                 "and that Steam Cloud is enabled for Civ 5")


def main():
    args = sys.argv[1:]
    if not args:
        sys.exit(__doc__)
    cmd = args[0]
    lib, storage, utils = load_api()
    print("Steam API initialized (app 8930)")

    if cmd == "quota":
        total, avail = ctypes.c_uint64(), ctypes.c_uint64()
        lib.SteamAPI_ISteamRemoteStorage_GetQuota(storage, ctypes.byref(total), ctypes.byref(avail))
        print(f"Cloud quota: {avail.value}/{total.value} bytes available")

    elif cmd == "publish":
        mod_path, preview_path, title, desc = args[1], args[2], args[3], args[4]
        public = "--public" in args
        cloud_write(lib, storage, os.path.basename(mod_path), mod_path)
        cloud_write(lib, storage, "workshop_preview.jpg", preview_path)

        tag_vals = (ctypes.c_char_p * 1)(b"Civilizations")
        tags = SteamParamStringArray(tag_vals, 1)
        call = lib.SteamAPI_ISteamRemoteStorage_PublishWorkshopFile(
            storage, os.path.basename(mod_path).encode(), b"workshop_preview.jpg",
            APPID, title.encode(), desc.encode(),
            VIS_PUBLIC if public else VIS_PRIVATE,
            ctypes.byref(tags), K_EWORKSHOP_FILE_TYPE_COMMUNITY)
        print(f"PublishWorkshopFile call issued ({'public' if public else 'private/hidden'})…")
        raw = wait_call(lib, utils, call, CB_PUBLISH_FILE_RESULT)
        eresult, file_id, needs_legal = parse_publish_result(raw)
        print(f"Result: {ERESULT.get(eresult, eresult)} (EResult {eresult})")
        if needs_legal:
            print("NOTE: you must accept the Steam Workshop legal agreement:")
            print("  https://steamcommunity.com/sharedfiles/workshoplegalagreement")
        if eresult == 1:
            print(f"PUBLISHED! File ID: {file_id}")
            print(f"  https://steamcommunity.com/sharedfiles/filedetails/?id={file_id}")

    elif cmd == "update":
        file_id, mod_path, note = int(args[1]), args[2], args[3]
        cloud_write(lib, storage, os.path.basename(mod_path), mod_path)
        req = lib.SteamAPI_ISteamRemoteStorage_CreatePublishedFileUpdateRequest(storage, file_id)
        lib.SteamAPI_ISteamRemoteStorage_UpdatePublishedFileFile(
            storage, req, os.path.basename(mod_path).encode())
        lib.SteamAPI_ISteamRemoteStorage_UpdatePublishedFileSetChangeDescription(
            storage, req, note.encode())
        call = lib.SteamAPI_ISteamRemoteStorage_CommitPublishedFileUpdate(storage, req)
        raw = wait_call(lib, utils, call, CB_UPDATE_FILE_RESULT)
        eresult, fid, needs_legal = parse_publish_result(raw)
        print(f"Update result: {ERESULT.get(eresult, eresult)} (EResult {eresult}) file {fid}")

    else:
        sys.exit(__doc__)

    lib.SteamAPI_Shutdown()


if __name__ == "__main__":
    main()
