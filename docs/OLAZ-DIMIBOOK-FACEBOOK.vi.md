# Ví dụ DIMI Book và phạm vi Facebook đầy đủ

Cập nhật: 08/11/2026, theo thông tin bổ sung của người dùng: website ví dụ `dimibook.com`, Facebook cần cả quảng cáo, Fanpage, bình luận và Messenger.

## 1. Website là cấu hình riêng, không gắn cứng trong Olaz

Olaz tiếp tục hỗ trợ nhiều website/MCP. `dimibook.com` là ví dụ cấu hình, chưa được tự thêm vào danh sách tài khoản thật, chưa lưu thông tin đăng nhập hoặc cấp quyền công cụ mới.

Cấu hình mẫu trong Plugin → Kết nối MCP → Thêm kết nối…:

| Trường | Giá trị ví dụ |
| --- | --- |
| Loại nguồn | WordPress; chọn WooCommerce nếu website thực sự cung cấp abilities của cửa hàng |
| Tên kết nối | DIMI Book |
| Website | `https://dimibook.com` |
| Endpoint gợi ý | `https://dimibook.com/wp-json/mcp/mcp-adapter-default-server` |
| Kiểu xác thực | Tên đăng nhập / mật khẩu (HTTP Basic) |
| Tên đăng nhập | Username WordPress của người được cấp quyền |
| Application Password | Nhập riêng trong app, không đưa vào tài liệu hoặc chat |
| Trạng thái ban đầu | Tắt; chưa cấp công cụ/ability |

**Kết quả kiểm tra công khai:** GET endpoint gợi ý trả HTTP 401, JSON `code: rest_forbidden`. Đây là phản hồi yêu cầu xác thực, chưa phải xác minh MCP handshake. Chưa có đăng nhập, chưa tải được catalog công cụ/abilities và chưa xác nhận WooCommerce đang bật. Một lớp bảo vệ REST API cũng có thể từ chối truy cập trước khi định tuyến tới MCP.

Không kết luận cần cài lại plugin chỉ từ HTTP 401. Cần dùng đúng thông tin đăng nhập rồi kiểm tra trong Olaz. Nếu website dùng custom MCP server, dùng endpoint do quản trị website cung cấp.

## 2. Các bước xác minh kết nối thật

1. Quản trị website xác nhận MCP Adapter/server tương ứng đang hoạt động.
2. Tạo Application Password cho tài khoản WordPress có quyền phù hợp. Người dùng nhập username và Application Password trực tiếp trong Olaz.
3. Lưu nguồn rồi bấm Kiểm tra và tải công cụ. Olaz phải hoàn tất initialize và đọc tools/list; HTTP 200 ở trang chủ không thay bước này.
4. Nếu có bộ ba discovery/info/execute của MCP Adapter, tải abilities và chọn từng ability cần dùng. Tên lấy từ server, không đoán theo tên website.
5. Bật nguồn và thử đọc một bài viết/sản phẩm đã biết. Đối chiếu tên, giá và đường dẫn với dữ liệu website.
6. Chỉ khi phép thử thành công mới chọn nguồn cho hội thoại Zalo hoặc dùng để trả lời khách. Kết nối thành công chưa đồng nghĩa mọi ability đều có quyền.

Ví dụ câu hỏi sau khi đã xác minh nguồn:

- Tìm các bài viết về dịch vụ xuất bản sách.
- Tìm sách theo tên hoặc ISBN, nếu công cụ/schema nguồn hỗ trợ.
- Cho ba lựa chọn sách trong ngân sách do khách cung cấp.
- Tra trạng thái đơn theo mã, khi tài khoản và nguồn có quyền đọc đơn.

Hướng dẫn AI và tài liệu local hiện dùng chung trong cấu hình AI. Không tự thay hướng dẫn Hoa tươi đang hoạt động bằng hướng dẫn DIMI Book. Khi dùng nhiều ngành hàng, cần rà soát hướng dẫn chung và chọn đúng nguồn cho từng hội thoại; hồ sơ hướng dẫn riêng theo thương hiệu là phần mở rộng cần bổ sung.

## 3. “Tất cả Facebook” được hiểu là phạm vi nào

| Nhóm | Công việc mục tiêu | Hiện trạng trong Olaz |
| --- | --- | --- |
| Meta Ads | Đọc chiến dịch, hiệu quả, chi phí; chuẩn bị nhận xét/báo cáo | Có mẫu Ads MCP và luồng xác thực; chưa có client Meta hợp lệ để xác minh đăng nhập thật |
| Fanpage | Tra thông tin trang/bài đăng, chuẩn bị nội dung và lịch xuất bản | Có kết nối MCP tùy chỉnh; cần server cung cấp công cụ Page và quyền tương ứng |
| Bình luận | Theo dõi bình luận, soạn câu trả lời, chuyển việc cho nhân viên | Chưa có nguồn bình luận/webhook thực tế được cấu hình |
| Messenger | Đọc hội thoại, soạn phản hồi, chế độ duyệt/tự động, người dùng tiếp quản | Chưa có Inbox Facebook hoặc luồng nhận/gửi Messenger trong app |
| Khách hàng và báo cáo | Liên kết cuộc trao đổi Facebook với nhu cầu/đơn hàng, tổng hợp công việc | Hồ sơ hiện gắn tài khoản/hội thoại Zalo; chưa đồng bộ CRM đa kênh |

Các hàng này là phạm vi đã chọn, không phải danh sách tính năng Facebook đã hoàn thành. Endpoint Ads không thay thế công cụ Fanpage/Messenger.

## 4. Các phần cần có để triển khai Facebook đầy đủ

### 4.1 Phần Olaz

- Nhóm nguồn Meta Ads và Page/Messenger tách biệt, mỗi nguồn có trạng thái xác thực, catalog và quyền riêng.
- Công cụ đọc phục vụ Trợ lý công việc; kết quả có nguồn và thời điểm tra cứu.
- Inbox có khóa tài khoản/trang/kênh/hội thoại. Không dùng ID hội thoại Facebook làm ID Zalo.
- Chính sách AI riêng cho từng hội thoại Facebook: bật/tắt, duyệt/tự động, thời gian tiếp quản và nguồn dữ liệu được chọn.
- Hàng đợi duyệt thao tác ghi: hiện trang/người nhận, nội dung và hành động cụ thể trước khi thực thi.
- Nhật ký thao tác và trạng thái lỗi, không lưu token trong nội dung nhật ký.

### 4.2 Phần server tích hợp

- MCP server cung cấp các công cụ Page/bình luận/Messenger thực tế, thay vì chỉ một form cấu hình URL.
- Luồng đăng nhập Meta, chọn trang/tài khoản được cấp quyền và quản lý vòng đời token ở đúng thành phần sử dụng token.
- Dịch vụ HTTPS nhận webhook cho sự kiện trang/tin nhắn, kiểm tra tính xác thực, chống xử lý lặp và lưu hàng đợi bền vững.
- Trạng thái giao việc cho nhân viên và xác nhận gửi; lỗi hoặc timeout không được gây gửi lại trùng.
- Áp dụng quyền tài khoản, chính sách và điều kiện gửi tin của Meta tại thời điểm tích hợp. Không lấy việc chọn tự động trong Olaz để bỏ qua điều kiện phía Meta.

### 4.3 Thông tin cần cấu hình trong app/hệ thống quản trị

- Meta App ID và client được chấp nhận, quyền với trang/tài khoản quảng cáo dự định dùng.
- Redirect URI cho đăng nhập; URL webhook nếu nhận sự kiện. Đây là hai mục đích khác nhau, không mặc định trỏ cả hai vào `/callback` của Olaz.
- MCP endpoint cho Page/Messenger, hoặc môi trường để triển khai server tích hợp riêng.
- Token/Client Secret nhập qua giao diện cấu hình riêng; không gửi vào chat hoặc commit vào repository.

## 5. Thứ tự triển khai theo phụ thuộc

1. Xác minh WordPress/WooCommerce của website thật và Meta Ads bằng thông tin client hợp lệ.
2. Triển khai/ghép MCP server đọc Page, bài viết, bình luận và Messenger; kiểm tra bằng tài khoản thử.
3. Xây Inbox Facebook và webhook, cơ chế tiếp quản và chống xử lý lặp.
4. Bổ sung hàng đợi duyệt trả lời/đăng bài, sau đó triển khai chế độ tự động trong giới hạn được cấu hình.
5. Liên kết khách hàng/đơn hàng theo kênh và báo cáo công việc đa nguồn.

Chưa tự tạo Meta App, cài plugin trên dimibook.com, dựng webhook công khai hoặc thực hiện bất kỳ thao tác đăng bài, gửi Messenger, sửa quảng cáo hay tạo đơn nào trong lần cập nhật tài liệu này.

## 6. Tài liệu liên quan

- [Hướng dẫn kết nối/sử dụng Olaz](OLAZ-INTEGRATIONS.vi.md)
- [Đặc tả và nhật ký triển khai](OLAZ-WORKSPACE-PLAN.vi.md)
- [WordPress MCP Adapter: hướng dẫn cho chủ website](https://github.com/WordPress/mcp-adapter/blob/trunk/docs/getting-started/site-owners.md)
- [WordPress MCP Adapter: server mặc định](https://github.com/WordPress/mcp-adapter/blob/trunk/docs/guides/default-server.md)

Các yêu cầu quyền cụ thể của Facebook sẽ được xác minh theo tài liệu Meta và cấu hình ứng dụng khi triển khai; chưa chốt danh sách scope hoặc phiên bản API từ phỏng đoán.
