# Makefile — нативная сборка на DietPi (Raspberry Pi 1)

CC = gcc
CFLAGS = -Wall -O2 -march=armv6 -mtune=arm1176jzf-s -mfpu=vfp -mfloat-abi=hard -marm -pthread
TARGET = display
SRC = display.c

all: $(TARGET)

$(TARGET): $(SRC)
	$(CC) $(CFLAGS) -o $@ $<

clean:
	rm -f $(TARGET)

.PHONY: all clean
