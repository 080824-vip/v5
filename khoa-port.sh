#!/bin/bash

# ==============================================================================
# Script Quản Lý Cổng - Kích Hoạt Dựa Trên Lưu Lượng (Tự Động Hoàn Toàn)
# Tác giả: Gemini (Tối ưu hóa dựa trên yêu cầu)
# Ngày cập nhật: 11/07/2025
#
# Mô tả:
# Phiên bản này hoạt động hoàn toàn tự động. Tất cả các cổng trong dải
# được xác định sẽ tự động được giám sát lưu lượng ngay từ đầu. Không cần
# cấu hình thủ công cho từng cổng.
#
# Logic hoạt động:
# 1. Khởi tạo: Tất cả các cổng tự động được đặt vào trạng thái MONITORING.
# 2. Giám sát tự động: Dịch vụ systemd chạy định kỳ để kiểm tra lưu lượng.
# 3. Kích hoạt tự động: Khi một cổng đạt ngưỡng lưu lượng, nó tự động được
#    kích hoạt và bắt đầu đếm ngược số ngày sử dụng.
# 4. Chặn tự động: Khi hết hạn, cổng sẽ tự động bị chặn.
# ==============================================================================

# --- CẤU HÌNH ---
PORT_RANGE_START=30000
PORT_RANGE_END=30349
TRAFFIC_THRESHOLD_BYTES=943718400 # 900MB
DEFAULT_VALID_DAYS=31 # Số ngày sử dụng mặc định sau khi kích hoạt

IPTABLES_CHAIN="PORT_MONITOR_CHAIN"
LOG_FILE="/var/log/port_manager.log"
DB_DIR="/var/lib/port_manager"
PORT_DB="${DB_DIR}/ports.db"
SCRIPT_PATH=$(realpath "$0")

# Định nghĩa màu sắc
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# --- HÀM TIỆN ÍCH ---

log_message() {
    local message
    message="[$(date '+%Y-%m-%d %H:%M:%S')] $1"
    echo "$message" | tee -a "$LOG_FILE"
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}Script này yêu cầu quyền root. Vui lòng chạy với sudo.${NC}"
        exit 1
    fi
}

check_dependencies() {
    local packages=("iptables" "sqlite3" "coreutils" "gawk" "numfmt" "bc")
    local missing_packages=()
    for package in "${packages[@]}"; do
        if ! command -v "$package" &> /dev/null; then
            missing_packages+=("$package")
        fi
    done

    if [ ${#missing_packages[@]} -ne 0 ]; then
        log_message "Đang cài đặt các gói cần thiết: ${missing_packages[*]}"
        apt-get update && apt-get install -y "${missing_packages[@]}"
    fi
}

# --- QUẢN LÝ CƠ SỞ DỮ LIỆU ---

setup_database() {
    mkdir -p "$DB_DIR"
    if [ ! -f "$PORT_DB" ]; then
        log_message "Đang tạo cơ sở dữ liệu mới tại $PORT_DB..."
        sqlite3 "$PORT_DB" <<EOF
CREATE TABLE ports (
    port INTEGER PRIMARY KEY,
    status TEXT DEFAULT 'monitoring', -- inactive, monitoring, active, blocked
    valid_days INTEGER DEFAULT ${DEFAULT_VALID_DAYS}, -- Số ngày sử dụng sau khi kích hoạt
    activation_date TEXT,           -- Ngày kích hoạt (đạt ngưỡng traffic)
    expiry_date TEXT                -- Ngày hết hạn (tính từ ngày kích hoạt)
);
EOF
        log_message "Đang thêm các cổng từ $PORT_RANGE_START đến $PORT_RANGE_END vào DB với trạng thái giám sát mặc định."
        for port in $(seq "$PORT_RANGE_START" "$PORT_RANGE_END"); do
            # Các giá trị mặc định (status, valid_days) sẽ được tự động áp dụng
            sqlite3 "$PORT_DB" "INSERT INTO ports (port) VALUES ($port);"
        done
        log_message "Tạo cơ sở dữ liệu và khởi tạo cổng thành công."
    else
        log_message "Sử dụng cơ sở dữ liệu đã có."
    fi
}

# Tự động chuyển các cổng chưa cấu hình sang trạng thái giám sát
initialize_all_ports() {
    log_message "Kiểm tra các cổng chưa được cấu hình..."
    # Tìm tất cả các cổng chưa được cấu hình (inactive) và đặt chúng vào chế độ giám sát.
    # Điều này đảm bảo tính tương thích ngược nếu chạy script với DB cũ.
    local inactive_ports_count
    inactive_ports_count=$(sqlite3 "$PORT_DB" "SELECT COUNT(*) FROM ports WHERE status = 'inactive';")

    if [ "$inactive_ports_count" -gt 0 ]; then
        echo "Phát hiện $inactive_ports_count cổng chưa được cấu hình."
        echo "Tự động đưa chúng vào trạng thái giám sát với $DEFAULT_VALID_DAYS ngày sử dụng..."
        
        sqlite3 "$PORT_DB" "UPDATE ports SET status = 'monitoring', valid_days = $DEFAULT_VALID_DAYS WHERE status = 'inactive';"
        
        log_message "Đã tự động chuyển $inactive_ports_count cổng sang trạng thái 'monitoring'."
        echo -e "${GREEN}Khởi tạo tự động hoàn tất!${NC}"
        sleep 2
    else
        log_message "Tất cả các cổng đã được cấu hình. Bỏ qua bước khởi tạo."
    fi
}


# --- QUẢN LÝ IPTABLES ---

setup_iptables_chain() {
    # Tạo chain chính nếu chưa tồn tại
    if ! iptables -L "$IPTABLES_CHAIN" -n > /dev/null 2>&1; then
        log_message "Tạo chain mới trong iptables: $IPTABLES_CHAIN"
        iptables -N "$IPTABLES_CHAIN"
        
        # Chuyển hướng lưu lượng từ INPUT sang chain tùy chỉnh để đếm
        iptables -I INPUT 1 -p tcp -m multiport --dports "$PORT_RANGE_START:$PORT_RANGE_END" -j "$IPTABLES_CHAIN"
        iptables -I INPUT 1 -p udp -m multiport --dports "$PORT_RANGE_START:$PORT_RANGE_END" -j "$IPTABLES_CHAIN"
    fi

    # Đảm bảo mỗi cổng có một quy tắc riêng để đếm lưu lượng
    log_message "Kiểm tra và thêm các quy tắc đếm lưu lượng cho từng cổng..."
    for port in $(seq "$PORT_RANGE_START" "$PORT_RANGE_END"); do
        if ! iptables -C "$IPTABLES_CHAIN" -p tcp --dport "$port" -j RETURN > /dev/null 2>&1; then
            iptables -A "$IPTABLES_CHAIN" -p tcp --dport "$port" -j RETURN
        fi
        if ! iptables -C "$IPTABLES_CHAIN" -p udp --dport "$port" -j RETURN > /dev/null 2>&1; then
            iptables -A "$IPTABLES_CHAIN" -p udp --dport "$port" -j RETURN
        fi
    done
    log_message "Thiết lập chain iptables hoàn tất."
}

block_port() {
    local port=$1
    log_message "Bắt đầu chặn cổng $port."
    iptables -I INPUT 1 -p tcp --dport "$port" -j DROP
    iptables -I INPUT 1 -p udp --dport "$port" -j DROP
    sqlite3 "$PORT_DB" "UPDATE ports SET status = 'blocked' WHERE port = $port;"
    log_message "Đã chặn thành công cổng $port."
}

unblock_port() {
    local port=$1
    # Không ghi log ở đây để tránh spam khi reset hàng loạt
    while iptables -D INPUT -p tcp --dport "$port" -j DROP 2>/dev/null; do :; done
    while iptables -D INPUT -p udp --dport "$port" -j DROP 2>/dev/null; do :; done
    
    # Reset cổng về trạng thái giám sát mặc định
    sqlite3 "$PORT_DB" "UPDATE ports SET status = 'monitoring', valid_days = ${DEFAULT_VALID_DAYS}, activation_date = NULL, expiry_date = NULL WHERE port = $port;"
}

reset_port_traffic_counter() {
    local port=$1
    # Không ghi log ở đây để tránh spam khi reset hàng loạt
    # Xóa và thêm lại quy tắc là cách chuẩn để reset bộ đếm cho một quy tắc cụ thể
    iptables -D "$IPTABLES_CHAIN" -p tcp --dport "$port" -j RETURN 2>/dev/null
    iptables -D "$IPTABLES_CHAIN" -p udp --dport "$port" -j RETURN 2>/dev/null
    iptables -A "$IPTABLES_CHAIN" -p tcp --dport "$port" -j RETURN
    iptables -A "$IPTABLES_CHAIN" -p udp --dport "$port" -j RETURN
}

# --- LOGIC CỐT LÕI ---

update_traffic_and_activate_ports() {
    log_message "Bắt đầu quá trình kiểm tra lưu lượng để kích hoạt cổng."
    local traffic_data
    traffic_data=$(iptables -L "$IPTABLES_CHAIN" -v -n -x)
    
    local monitoring_ports_query="SELECT port, valid_days FROM ports WHERE status = 'monitoring';"
    
    sqlite3 "$PORT_DB" "$monitoring_ports_query" | while IFS='|' read -r port valid_days; do
        if [ -z "$port" ]; then continue; fi
        
        # Lệnh awk được tối ưu để tìm kiếm pattern 'dpt:PORT' một cách ổn định và cộng dồn lưu lượng
        local total_bytes
        total_bytes=$(echo "$traffic_data" | awk -v p="$port" '($0 ~ "dpt:"p" "){sum+=$2} END {print sum+0}')

        log_message "Kiểm tra cổng $port: Lưu lượng hiện tại là $total_bytes bytes."

        if [ "$total_bytes" -ge "$TRAFFIC_THRESHOLD_BYTES" ]; then
            log_message "Cổng $port đã đạt ngưỡng lưu lượng ($total_bytes bytes). Tiến hành kích hoạt."
            
            local current_date
            current_date=$(date '+%Y-%m-%d')
            local expiry_date
            expiry_date=$(date -d "$current_date + $valid_days days" '+%Y-%m-%d')
            
            sqlite3 "$PORT_DB" "UPDATE ports SET status = 'active', activation_date = '$current_date', expiry_date = '$expiry_date' WHERE port = $port;"
            log_message "Cổng $port đã được kích hoạt. Ngày hết hạn: $expiry_date."
        fi
    done
    log_message "Hoàn tất quá trình kiểm tra lưu lượng."
}

check_and_block_expired_ports() {
    log_message "Bắt đầu quá trình kiểm tra và khóa các cổng đã hết hạn."
    local current_date
    current_date=$(date '+%Y-%m-%d')
    local active_ports_query="SELECT port, expiry_date FROM ports WHERE status = 'active';"
    
    sqlite3 "$PORT_DB" "$active_ports_query" | while IFS='|' read -r port expiry_date; do
        if [ -n "$port" ] && [ -n "$expiry_date" ]; then
            if [[ "$current_date" > "$expiry_date" ]]; then
                log_message "Cổng $port đã hết hạn vào ngày $expiry_date. Tiến hành khóa."
                block_port "$port"
            fi
        fi
    done
    log_message "Hoàn tất quá trình kiểm tra cổng hết hạn."
}

# --- CHỨC NĂNG MENU ---

show_status() {
    clear
    echo -e "${BLUE}=== TRẠNG THÁI CỔNG (Ngưỡng kích hoạt: $(numfmt --to=iec-i --suffix=B "$TRAFFIC_THRESHOLD_BYTES")) ===${NC}"
    printf "%-8s %-12s %-12s %-18s %-18s\n" "Cổng" "Trạng Thái" "Ngày SD" "Ngày Kích Hoạt" "Ngày Hết Hạn"
    echo "--------------------------------------------------------------------------"
    
    sqlite3 "$PORT_DB" "SELECT port, status, valid_days, activation_date, expiry_date FROM ports ORDER BY port;" | \
    while IFS='|' read -r port status valid_days activation_date expiry_date; do
        local status_color=$NC
        case "$status" in
            "active")     status_color=$GREEN ;;
            "blocked")    status_color=$RED ;;
            "monitoring") status_color=$YELLOW ;;
        esac
        
        printf "%-8s ${status_color}%-12s${NC} %-12s %-18s %-18s\n" \
            "$port" \
            "$(echo "$status" | tr 'a-z' 'A-Z')" \
            "${valid_days:-N/A}" \
            "${activation_date:-Chưa kích hoạt}" \
            "${expiry_date:-N/A}"
    done
    
    echo "--------------------------------------------------------------------------"
    read -rp "Nhấn Enter để quay lại menu..."
}

check_single_port_traffic_menu() {
    clear
    echo -e "${BLUE}=== KIỂM TRA LƯU LƯỢNG MỘT CỔNG ===${NC}"
    read -rp "Nhập số cổng cần kiểm tra: " port

    if ! [[ "$port" =~ ^[0-9]+$ ]] || [ "$port" -lt "$PORT_RANGE_START" ] || [ "$port" -gt "$PORT_RANGE_END" ]; then
        echo -e "${RED}Lỗi: Cổng '$port' không hợp lệ.${NC}"
        read -rp "Nhấn Enter để thử lại..."; return
    fi

    local status
    status=$(sqlite3 "$PORT_DB" "SELECT status FROM ports WHERE port = '$port';")

    if [[ "$status" != "monitoring" ]]; then
        echo -e "${YELLOW}Cổng $port không ở trạng thái giám sát. Trạng thái hiện tại: $(echo "$status" | tr 'a-z' 'A-Z')${NC}"
    else
        echo "Đang lấy dữ liệu lưu lượng cho cổng $port..."
        local traffic_data
        traffic_data=$(iptables -L "$IPTABLES_CHAIN" -v -n -x)
        local current_bytes
        current_bytes=$(echo "$traffic_data" | awk -v p="$port" '($0 ~ "dpt:"p" "){sum+=$2} END {print sum+0}')

        local current_mb
        current_mb=$(echo "scale=2; $current_bytes / 1024 / 1024" | bc)
        local threshold_mb
        threshold_mb=$(echo "scale=0; $TRAFFIC_THRESHOLD_BYTES / 1024 / 1024" | bc)
        
        # Tính phần trăm, tránh chia cho 0
        local percentage=0
        if (( $(echo "$TRAFFIC_THRESHOLD_BYTES > 0" | bc -l) )); then
            percentage=$(echo "scale=2; 100 * $current_bytes / $TRAFFIC_THRESHOLD_BYTES" | bc)
        fi

        echo "----------------------------------------"
        echo -e "Cổng: ${BLUE}$port${NC}"
        echo -e "Trạng thái: ${YELLOW}MONITORING${NC}"
        printf "Lưu lượng đã sử dụng: %.2f MB / %d MB\n" "$current_mb" "$threshold_mb"
        printf "Tiến độ kích hoạt: %.2f%%\n" "$percentage"
        echo "----------------------------------------"
    fi

    read -rp "Nhấn Enter để quay lại menu..."
}


unblock_port_menu() {
    clear
    echo -e "${BLUE}=== MỞ KHÓA & RESET MỘT CỔNG ===${NC}"
    echo "Thao tác này sẽ đưa cổng về lại trạng thái giám sát ban đầu."
    read -rp "Nhập số cổng cần mở khóa/reset: " port
    
    local status
    status=$(sqlite3 "$PORT_DB" "SELECT status FROM ports WHERE port = '$port';")
    
    if [ "$status" == "monitoring" ]; then
        echo -e "${YELLOW}Cổng $port vốn đã ở trạng thái giám sát.${NC}"
    else
        log_message "Bắt đầu mở khóa và reset thủ công cổng $port."
        unblock_port "$port"
        reset_port_traffic_counter "$port"
        echo -e "${GREEN}Cổng $port đã được reset về trạng thái MONITORING.${NC}"
    fi
    
    read -rp "Nhấn Enter để quay lại menu..."
}

block_port_menu() {
    clear
    echo -e "${BLUE}=== CHẶN MỘT CỔNG THỦ CÔNG ===${NC}"
    read -rp "Nhập số cổng cần chặn ngay lập tức: " port

    if ! [[ "$port" =~ ^[0-9]+$ ]] || [ "$port" -lt "$PORT_RANGE_START" ] || [ "$port" -gt "$PORT_RANGE_END" ]; then
        echo -e "${RED}Lỗi: Cổng '$port' không hợp lệ.${NC}"
        read -rp "Nhấn Enter để thử lại..."; return
    fi

    local status
    status=$(sqlite3 "$PORT_DB" "SELECT status FROM ports WHERE port = '$port';")

    if [[ "$status" == "blocked" ]]; then
        echo -e "${YELLOW}Cổng $port đã bị chặn từ trước.${NC}"
    else
        log_message "Bắt đầu chặn thủ công cổng $port."
        block_port "$port"
        echo -e "${GREEN}Cổng $port đã được chặn thành công.${NC}"
    fi

    read -rp "Nhấn Enter để quay lại menu..."
}

manage_automation_menu() {
    local service_name="port-manager-traffic"
    local service_file="/etc/systemd/system/${service_name}.service"
    local timer_file="/etc/systemd/system/${service_name}.timer"

    clear
    echo -e "${BLUE}=== CÀI ĐẶT CHẠY TỰ ĐỘNG (SYSTEMD) ===${NC}"

    if systemctl is-active --quiet "${service_name}.timer"; then
        echo -e "Trạng thái: ${GREEN}ĐANG HOẠT ĐỘNG${NC}"
        echo "Dịch vụ được cấu hình để chạy mỗi 30 phút."
        echo ""
        echo "1. Gỡ bỏ dịch vụ chạy tự động"
        echo "0. Quay lại"
        read -rp "Lựa chọn: " choice
        if [[ "$choice" == "1" ]]; then
            echo "Đang dừng và vô hiệu hóa timer..."
            systemctl stop "${service_name}.timer"
            systemctl disable "${service_name}.timer"
            echo "Đang xóa file dịch vụ..."
            rm -f "$service_file" "$timer_file"
            systemctl daemon-reload
            echo -e "${GREEN}Đã gỡ bỏ dịch vụ chạy tự động thành công.${NC}"
        fi
    else
        echo -e "Trạng thái: ${YELLOW}KHÔNG HOẠT ĐỘNG${NC}"
        echo ""
        echo "1. Cài đặt dịch vụ chạy tự động (mỗi 30 phút)"
        echo "0. Quay lại"
        read -rp "Lựa chọn: " choice
        if [[ "$choice" == "1" ]]; then
            echo "Đang tạo file service..."
            cat > "$service_file" << EOF
[Unit]
Description=Port Manager (Traffic Based) - Check for traffic and expirations
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
ExecStart=$SCRIPT_PATH auto
EOF
            echo "Đang tạo file timer..."
            cat > "$timer_file" << EOF
[Unit]
Description=Run Port Manager (Traffic Based) service every 30 minutes

[Timer]
OnBootSec=2min
OnCalendar=*:0/30
Persistent=true

[Install]
WantedBy=timers.target
EOF
            echo "Đang kích hoạt dịch vụ..."
            systemctl daemon-reload
            systemctl enable --now "${service_name}.timer"
            echo -e "${GREEN}Đã cài đặt và kích hoạt dịch vụ chạy tự động thành công!${NC}"
        fi
    fi
    read -rp "Nhấn Enter để quay lại menu..."
}

reset_all_ports_menu() {
    clear
    echo -e "${BLUE}=== RESET NHANH TẤT CẢ CỔNG ===${NC}"
    echo -e "${RED}CẢNH BÁO: Thao tác này sẽ mở khóa TẤT CẢ các cổng, xóa toàn bộ cấu hình${NC}"
    echo -e "${RED}và đặt lại bộ đếm lưu lượng của chúng về 0. KHÔNG THỂ HOÀN TÁC.${NC}"
    echo ""
    read -rp "Bạn có hoàn toàn chắc chắn muốn tiếp tục? (nhập 'yes' để xác nhận): " confirm

    if [[ "$confirm" == "yes" ]]; then
        log_message "Bắt đầu quá trình reset tất cả các cổng."
        echo "Đang xử lý, việc này có thể mất một lúc..."

        for port in $(seq "$PORT_RANGE_START" "$PORT_RANGE_END"); do
            unblock_port "$port"
            reset_port_traffic_counter "$port"
        done

        log_message "Đã hoàn tất quá trình reset tất cả các cổng."
        echo -e "${GREEN}Tất cả các cổng đã được reset thành công về trạng thái MONITORING.${NC}"
    else
        echo -e "${YELLOW}Thao tác đã được hủy.${NC}"
    fi

    read -rp "Nhấn Enter để quay lại menu..."
}


# --- VÒNG LẶP CHÍNH ---

show_menu() {
    while true; do
        clear
        echo -e "${BLUE}======================================================${NC}"
        echo -e "${BLUE}=== SCRIPT QUẢN LÝ CỔNG (TỰ ĐỘNG THEO LƯU LƯỢNG) ===${NC}"
        echo -e "${BLUE}======================================================${NC}"
        echo "1. Xem trạng thái tất cả cổng"
        echo "2. Kiểm tra lưu lượng một cổng"
        echo "3. Mở khóa & Reset một cổng"
        echo "4. Chặn một cổng thủ công"
        echo "5. Chạy kiểm tra thủ công (Kích hoạt & Khóa)"
        echo "6. Cài đặt Chạy Tự Động (Systemd)"
        echo -e "${YELLOW}7. Reset Nhanh Tất Cả Cổng (Thao tác nguy hiểm)${NC}"
        echo "0. Thoát"
        echo ""
        read -rp "Nhập lựa chọn của bạn: " choice
        
        case $choice in
            1) show_status ;;
            2) check_single_port_traffic_menu ;;
            3) unblock_port_menu ;;
            4) block_port_menu ;;
            5) 
                update_traffic_and_activate_ports
                check_and_block_expired_ports
                read -rp "Hoàn tất kiểm tra thủ công. Nhấn Enter..."
                ;;
            6) manage_automation_menu ;;
            7) reset_all_ports_menu ;;
            0) echo -e "${GREEN}Đang thoát...${NC}"; exit 0 ;;
            *) echo -e "${RED}Lựa chọn không hợp lệ.${NC}"; sleep 2 ;;
        esac
    done
}

main() {
    check_root
    
    if [ "$1" = "auto" ]; then
        # Khi chạy tự động, không cần kiểm tra phụ thuộc mỗi lần
        log_message "Chạy ở chế độ tự động."
        update_traffic_and_activate_ports
        check_and_block_expired_ports
        exit 0
    fi
    
    # Chỉ chạy các hàm setup khi ở chế độ tương tác
    check_dependencies
    setup_database
    setup_iptables_chain
    initialize_all_ports # Tự động cấu hình các cổng chưa được giám sát
    show_menu
}

main "$@"
