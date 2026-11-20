//
//  ios_system_stub.h
//  WQTerm
//
//  Prototype stub cho hàm C ios_system (a-Shell).
//  Chứa thông tin kiểu để tránh "conflicting types" nếu có header khác khai báo.
//  TODO: Thay bằng header thật từ xcframework holzschu/ios_system.
//

#ifndef IOS_SYSTEM_STUB_H
#define IOS_SYSTEM_STUB_H

#include <stdio.h>

/* TODO: thay bằng khai báo thật từ xcframework holzschu/ios_system */
int ios_system(const char *cmd);

#endif /* IOS_SYSTEM_STUB_H */
