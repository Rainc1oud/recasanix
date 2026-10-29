package main

import (
	"encoding/binary"
	"errors"
	"os"
	"syscall"
	"unsafe"
)

// The btrfs ioctls read here (linux/btrfs.h; numbers and offsets checked against the 7.2 headers).
// All three only read: no write access to the filesystem, CAP_SYS_ADMIN for scrub and replace status.
const (
	iocScrubProgress = 0xc400941d // _IOWR(0x94, 29, struct btrfs_ioctl_scrub_args), 1024 bytes
	iocDevInfo       = 0xd000941e // _IOWR(0x94, 30, struct btrfs_ioctl_dev_info_args), 4096 bytes
	iocDevReplace    = 0xca289435 // _IOWR(0x94, 53, struct btrfs_ioctl_dev_replace_args), 2600 bytes

	devReplaceCmdStatus   = 1
	devReplaceStateActive = 1 // BTRFS_IOCTL_DEV_REPLACE_STATE_STARTED
)

type sysBtrfs struct{}

func (sysBtrfs) Devices(dev string) (uint64, error) { return superblockDevices(dev) }

func ioctlOn(mount string, req uintptr, buf []byte) error {
	f, err := os.Open(mount)
	if err != nil {
		return err
	}
	defer f.Close()
	if _, _, errno := syscall.Syscall(syscall.SYS_IOCTL, f.Fd(), req, uintptr(unsafe.Pointer(&buf[0]))); errno != 0 {
		return errno
	}
	return nil
}

func (sysBtrfs) DevInfo(mount string, devid uint64) (string, uint64, error) {
	buf := make([]byte, 4096)
	binary.NativeEndian.PutUint64(buf[0:], devid)
	if err := ioctlOn(mount, iocDevInfo, buf); err != nil {
		return "", 0, err
	}
	path := buf[3072:]
	for i, c := range path {
		if c == 0 {
			path = path[:i]
			break
		}
	}
	return string(path), binary.NativeEndian.Uint64(buf[32:]), nil
}

func (sysBtrfs) ScrubProgress(mount string, devid uint64) (bool, uint64, error) {
	buf := make([]byte, 1024)
	binary.NativeEndian.PutUint64(buf[0:], devid)
	if err := ioctlOn(mount, iocScrubProgress, buf); err != nil {
		if errors.Is(err, syscall.ENOTCONN) { // no scrub on this device
			return false, 0, nil
		}
		return false, 0, err
	}
	// progress.data_bytes_scrubbed, progress.tree_bytes_scrubbed
	return true, binary.NativeEndian.Uint64(buf[48:]) + binary.NativeEndian.Uint64(buf[56:]), nil
}

func (sysBtrfs) ReplaceProgress(mount string) (bool, uint64, error) {
	buf := make([]byte, 2600)
	binary.NativeEndian.PutUint64(buf[0:], devReplaceCmdStatus)
	if err := ioctlOn(mount, iocDevReplace, buf); err != nil {
		return false, 0, err
	}
	// status.replace_state, status.progress_1000
	return binary.NativeEndian.Uint64(buf[16:]) == devReplaceStateActive, binary.NativeEndian.Uint64(buf[24:]), nil
}
