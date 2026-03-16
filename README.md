# MTProto
Автоматическое создание и управление портами для MTProto

# 1. Скачать и установить
```bash
sudo curl -fsSL https://raw.githubusercontent.com/androideworld/MTProto/main/mtproto-manager_2.1.sh \
    -o /usr/local/bin/mtproto-manager
```

# 2. Сделать исполняемым
```bash
sudo chmod +x /usr/local/bin/mtproto-manager
```

# 3. Проверка
✅ Должно быть: #!/bin/bash$

```bash
head -1 /usr/local/bin/mtproto-manager | cat -A
```

Синтаксис

```bash
sudo bash -n /usr/local/bin/mtproto-manager && echo "✅ Синтаксис ОК"
```

# 4.📋 Быстрая проверка одной командой

```bash
sudo chmod +x /usr/local/bin/mtproto-manager && \
head -1 /usr/local/bin/mtproto-manager | cat -A && \
sudo bash -n /usr/local/bin/mtproto-manager && echo "✅ ОК" && \
sudo mtproto-manager
```

# 5. Установка и запуск меню управления портами

```bash
sudo mtproto-manager
```
