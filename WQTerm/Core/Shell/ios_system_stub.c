//
//  ios_system_stub.c
//  WQTerm
//
//  Stub tạm thời cho hàm C ios_system (a-Shell) để link xong build.
//  TODO: Thay bằng thư viện ios_system thật (xcframework holzschu/ios_system).
//  Hiện tại mọi lệnh shell đều trả về -1 (thất bại), chưa chạy thực.
//
//  Chữ ký phải khớp với khai báo Swift trong CommandRunner.swift:
//    @_silgen_name("ios_system")
//    private func ios_system(_ command: UnsafePointer<Int8>) -> Int32
//  tương đương C: int ios_system(const char *cmd);
//

#include <stdio.h>

/* TODO: thay bằng ios_system thật từ xcframework holzschu/ios_system */
int ios_system(const char *cmd) {
    (void)cmd;
    return -1;
}
