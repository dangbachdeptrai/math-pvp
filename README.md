# MathMaster — Web học Toán & thi trắc nghiệm

Ứng dụng Next.js 14 (App Router), Tailwind CSS, Supabase và Socket.io cho luyện thi VACT/THPTQG/TSA, PvP, AI Tutor và kho học liệu.

## Chạy ứng dụng

1. Cài Node.js 20.9+ và pnpm 9+.
2. Sao chép `.env.example` thành `.env.local`, rồi điền URL/anon key Supabase. Socket cần thêm `SUPABASE_SERVICE_ROLE_KEY` để chấm PvP bằng đáp án bảo mật.
3. Mở Supabase SQL Editor, chạy toàn bộ [`supabase_schema.sql`](supabase_schema.sql). Trong Authentication, bật Email, Anonymous Sign-ins và cấu hình Google/Facebook với callback `http://localhost:3000/auth/callback`.
4. Cài và chạy hai tiến trình:

```bash
pnpm install
pnpm dev
pnpm socket
```

Mở `http://localhost:3000`. Server Socket mặc định chạy ở cổng 3001. Trước khi triển khai, đặt `NEXT_PUBLIC_APP_URL`, `NEXT_PUBLIC_SOCKET_URL` và URL callback OAuth bằng domain thật.

## Kiểm tra

```bash
pnpm typecheck
pnpm build
```

## Bảo mật và luồng dữ liệu

- Khóa đáp án ở bảng `question_answer_keys` không được đọc bởi học sinh. Hàm Postgres `submit_exam_attempt` chấm bài trong transaction và chỉ trả kết quả đã chấm.
- Tài liệu được lưu trong bucket private; policy Storage kiểm tra thư mục mang UUID của người tải. Màn xem dùng signed URL thời hạn 30 phút.
- Socket server kiểm tra đáp án ở server (dùng service role) và không tin điểm do client gửi.
- Dùng `OPENAI_API_KEY` hoặc `GEMINI_API_KEY` để bật AI Tutor. Khóa chỉ nằm ở server route, không bao giờ xuất hiện trong bundle trình duyệt.

## Ghi chú triển khai

Next.js và Socket.io chạy riêng để hỗ trợ kết nối WebSocket ổn định trên hạ tầng server/container. Khi scale ngang socket server, dùng Socket.io Redis adapter và thay state in-memory bằng Redis; schema `pvp_matches` / `pvp_match_players` đã sẵn sàng để lưu lịch sử trận.
