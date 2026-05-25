-- Pilot seed: store_001
-- Telegram chat IDs updated by 04-seed-env.sh from infra/.env

INSERT INTO regionals (regional_id, full_name, telegram_chat_id)
VALUES ('reg_01', 'Иван Регионалов', '0')
ON CONFLICT (regional_id) DO NOTHING;

INSERT INTO employees (employee_id, store_id, full_name, telegram_chat_id, regional_id)
VALUES ('emp_042', 'store_001', 'Мария Продавцова', '0', 'reg_01')
ON CONFLICT (employee_id) DO NOTHING;
