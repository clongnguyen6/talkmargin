# Weekly sync - Dự án Payment

## 1. Mở đầu (2 phút)
- Cảm ơn mọi người đã tham gia
- Mục tiêu hôm nay: **chốt timeline release v2** và phân công QA

## 2. Cập nhật tiến độ
- Backend API: *xong 90%*, còn phần refund
- Mobile: đang chờ design mới cho màn hình checkout
- [x] Đã fix bug double-charge
- [ ] Chưa có load test

> Nhớ nhắc: số liệu conversion tuần này tăng 12%

## 3. Rủi ro
1. Vendor SMS có thể trễ API key
2. QA thiếu người trong tuần 42
   - Đề xuất: mượn 1 bạn từ team Growth

---

## 4. Câu hỏi cần chốt
- Release ngày **15/10** hay **22/10**?
- Ai owner phần monitoring sau release?

## 5. Kết thúc
- Tóm tắt action items, gửi recap qua Slack trong `#payment-v2`

## 6. Q&A chuẩn bị sẵn

### Refund lỗi thì retry mấy lần?
- `RefundWorker` retry **3 lần**, backoff 2s → 4s → 8s
- Hết retry: đưa vào hàng đợi xử lý tay, alert trên Slack

### Sao không release 15/10?
- Refund còn 10%, chưa có load test
- QA thiếu người tuần 42 → 22/10 an toàn hơn

### Ai trực monitoring sau release?
- Tuần đầu: team Payment luân phiên, lịch trên Confluence

### Chi phí vendor SMS?
- Giữ hợp đồng cũ tới hết Q4, đàm phán lại tháng 12
