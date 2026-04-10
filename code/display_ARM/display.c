// display.c — ФИНАЛЬНАЯ СТАБИЛЬНАЯ ВЕРСИЯ (один раз malloc + reuse буфера)

#include <stdio.h>
#include <stdlib.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/mman.h>
#include <sys/ioctl.h>
#include <linux/fb.h>
#include <string.h>
#include <time.h>
#include <stdint.h>
#include <pthread.h>
#include <signal.h>

#define ANIM_FRAMES 60
#define ANIM_W      24
#define ANIM_H      24
#define ANIM_X      3
#define ANIM_Y      3
#define ANIM_DELAY  (1000000 / 10)

#define SCREEN_W    1024
#define SCREEN_H    600
#define BUFFER_SIZE ((size_t)SCREEN_W * SCREEN_H * 2)

#define TRANSPARENT_COLOR 0xF990
#define BG_COLOR          0x0000

// ====================== ГЛИФЫ ======================
uint16_t *digit_white[10] = {0};
uint16_t *digit_red[10]   = {0};
uint16_t *colon_white = NULL, *colon_red = NULL;
uint16_t *dot_white   = NULL, *dot_red   = NULL;
uint16_t *day_white[7] = {0};
uint16_t *day_red[7]   = {0};

const int DIGIT_W = 12, DIGIT_H = 30;
const int COLON_W = 12, DOT_W = 12;
const int DAY_W = 150, DAY_H = 30;

const int TIME_X = 200, DATE_X = 350, DAY_X = 530, INFO_Y = 0;

// ====================== ГЛОБАЛЬНЫЕ ======================
int fbfd = -1;
char *fbp = NULL;
struct fb_fix_screeninfo finfo;
long screensize = 0;

int offline_mode = 0;
time_t offline_start = 0;
int consecutive_fails = 0;
volatile int running = 1;

unsigned char *all_data_buffer = NULL;     // выделяется один раз
unsigned char *background_buffer = NULL;
unsigned char *offscreen_buffer = NULL;

pthread_mutex_t buffer_mutex = PTHREAD_MUTEX_INITIALIZER;

// ====================== ЗАГРУЗКА ======================
uint16_t* load_rgb565(const char *filename, int w, int h) {
    FILE *f = fopen(filename, "rb");
    if (!f) return NULL;
    uint16_t *buf = malloc((size_t)w * h * 2);
    if (buf) fread(buf, 2, (size_t)w * h, f);
    fclose(f);
    return buf;
}

void load_all_glyphs(void) {
    char path[256];
    for (int i = 0; i < 10; i++) {
        sprintf(path, "./digits/white/digit_%d.rgb565", i);
        digit_white[i] = load_rgb565(path, DIGIT_W, DIGIT_H);
        sprintf(path, "./digits/red/digit_%d.rgb565", i);
        digit_red[i]   = load_rgb565(path, DIGIT_W, DIGIT_H);
    }
    colon_white = load_rgb565("./digits/white/colon.rgb565", COLON_W, DIGIT_H);
    colon_red   = load_rgb565("./digits/red/colon.rgb565",   COLON_W, DIGIT_H);
    dot_white   = load_rgb565("./digits/white/dot.rgb565",   DOT_W,   DIGIT_H);
    dot_red     = load_rgb565("./digits/red/dot.rgb565",     DOT_W,   DIGIT_H);

    const char *days[7] = {"sunday","monday","tuesday","wednesday","thursday","friday","saturday"};
    for (int i = 0; i < 7; i++) {
        sprintf(path, "./digits/white/%s.rgb565", days[i]);
        day_white[i] = load_rgb565(path, DAY_W, DAY_H);
        sprintf(path, "./digits/red/%s.rgb565", days[i]);
        day_red[i]   = load_rgb565(path, DAY_W, DAY_H);
    }
    printf("✓ Глифы загружены\n");
}

// ====================== ВСПОМОГАТЕЛЬНЫЕ ======================
void clear_area_offscreen(unsigned char *buf, int x, int y, int w, int h) {
    for (int row = 0; row < h; row++) {
        uint16_t *dst = (uint16_t*)(buf + ((y + row) * (long)SCREEN_W * 2 + x * 2));
        for (int col = 0; col < w; col++) dst[col] = BG_COLOR;
    }
}

void draw_glyph_offscreen(unsigned char *buf, int x, int y, uint16_t *glyph, int w, int h) {
    if (!glyph) return;
    for (int row = 0; row < h; row++) {
        uint16_t *src = glyph + row * w;
        uint16_t *dst = (uint16_t*)(buf + ((y + row) * (long)SCREEN_W * 2 + x * 2));
        for (int col = 0; col < w; col++) {
            if (src[col] != TRANSPARENT_COLOR)
                dst[col] = src[col];
        }
    }
}

void update_local_fields_offscreen(unsigned char *buf) {
    time_t now = time(NULL);
    struct tm *tm = localtime(&now);

    uint16_t **digits = offline_mode ? digit_red : digit_white;
    uint16_t **days   = offline_mode ? day_red   : day_white;
    uint16_t *colon   = offline_mode ? colon_red : colon_white;
    uint16_t *dot     = offline_mode ? dot_red   : dot_white;

    char str[16];
    int x_pos;

    clear_area_offscreen(buf, DAY_X, INFO_Y, DAY_W, DAY_H);
    draw_glyph_offscreen(buf, DAY_X, INFO_Y, days[tm->tm_wday], DAY_W, DAY_H);

    clear_area_offscreen(buf, DATE_X, INFO_Y, 160, DIGIT_H);
    if (offline_mode) {
        int days_off = (int)((now - offline_start) / 86400);
        sprintf(str, "%d", days_off);
        x_pos = DATE_X;
        for (char *c = str; *c; c++) {
            if (*c >= '0' && *c <= '9') {
                draw_glyph_offscreen(buf, x_pos, INFO_Y, digits[*c-'0'], DIGIT_W, DIGIT_H);
                x_pos += DIGIT_W;
            }
        }
    } else {
        strftime(str, sizeof(str), "%d.%m.%Y", tm);
        x_pos = DATE_X;
        for (char *c = str; *c; c++) {
            if (*c >= '0' && *c <= '9') {
                draw_glyph_offscreen(buf, x_pos, INFO_Y, digits[*c-'0'], DIGIT_W, DIGIT_H);
                x_pos += DIGIT_W;
            } else if (*c == '.') {
                draw_glyph_offscreen(buf, x_pos, INFO_Y, dot, DOT_W, DIGIT_H);
                x_pos += DOT_W;
            }
        }
    }

    clear_area_offscreen(buf, TIME_X, INFO_Y, 130, DIGIT_H);
    if (offline_mode) {
        time_t elapsed = now - offline_start;
        int hh = (elapsed / 3600) % 100;
        int mm = (elapsed % 3600) / 60;
        int ss = elapsed % 60;
        sprintf(str, "%02d:%02d:%02d", hh, mm, ss);
        x_pos = TIME_X;
        for (char *c = str; *c; c++) {
            if (*c >= '0' && *c <= '9') {
                draw_glyph_offscreen(buf, x_pos, INFO_Y, digits[*c-'0'], DIGIT_W, DIGIT_H);
                x_pos += DIGIT_W;
            } else if (*c == ':') {
                draw_glyph_offscreen(buf, x_pos, INFO_Y, colon, COLON_W, DIGIT_H);
                x_pos += COLON_W;
            }
        }
    } else {
        strftime(str, sizeof(str), "%H:%M:%S", tm);
        x_pos = TIME_X;
        for (char *c = str; *c; c++) {
            if (*c >= '0' && *c <= '9') {
                draw_glyph_offscreen(buf, x_pos, INFO_Y, digits[*c-'0'], DIGIT_W, DIGIT_H);
                x_pos += DIGIT_W;
            } else if (*c == ':') {
                draw_glyph_offscreen(buf, x_pos, INFO_Y, colon, COLON_W, DIGIT_H);
                x_pos += COLON_W;
            }
        }
    }
}

void overlay_all_data_offscreen(unsigned char *buf, unsigned char *data) {
    if (!data) return;
    for (int y = 0; y < SCREEN_H; y++) {
        uint16_t *src = (uint16_t*)(data + (long)y * (long)SCREEN_W * 2);
        uint16_t *dst = (uint16_t*)(buf + (long)y * (long)SCREEN_W * 2);
        for (int x = 0; x < SCREEN_W; x++) {
            if (src[x] != TRANSPARENT_COLOR) dst[x] = src[x];
        }
    }
}

// ====================== ПОТОК СКАЧИВАНИЯ ======================
void* download_thread(void* arg) {
    const char *tmpfile = "/tmp/all_data.rgb565";

    while (running) {
        char cmd[256];
        sprintf(cmd, "wget -q --timeout=10 --tries=3 -O %s http://192.168.0.127/all_data.rgb565 2>/dev/null", tmpfile);
        system(cmd);

        FILE *f = fopen(tmpfile, "rb");
        if (f) {
            fseek(f, 0, SEEK_END);
            long size = ftell(f);
            fseek(f, 0, SEEK_SET);

            if (size == (long)BUFFER_SIZE) {
                // Читаем прямо в уже выделенный буфер
                pthread_mutex_lock(&buffer_mutex);
                if (fread(all_data_buffer, 1, BUFFER_SIZE, f) == BUFFER_SIZE) {
                    pthread_mutex_unlock(&buffer_mutex);

                    consecutive_fails = 0;
                    if (offline_mode) {
                        offline_mode = 0;
                        offline_start = 0;
                        printf("[OK] all_data.rgb565 получен — выход из оффлайн\n");
                    } else {
                        printf("[OK] all_data.rgb565 получен\n");
                    }
                } else {
                    pthread_mutex_unlock(&buffer_mutex);
                    consecutive_fails++;
                    printf("[ERROR] Ошибка чтения файла\n");
                }
            } else {
                consecutive_fails++;
                printf("[ERROR] Неправильный размер: %ld байт\n", size);
            }
            fclose(f);
        } else {
            consecutive_fails++;
        }

        remove(tmpfile);

        if (consecutive_fails >= 3 && offline_start == 0) {
            offline_mode = 1;
            offline_start = time(NULL);
            printf("[OFFLINE] Режим оффлайн активирован\n");
        }

        sleep(2);
    }
    return NULL;
}

void signal_handler(int sig) {
    printf("\n[INFO] Получен сигнал %d — завершение...\n", sig);
    running = 0;
}

// ====================== MAIN ======================
int main(void) {
    signal(SIGINT, signal_handler);
    signal(SIGTERM, signal_handler);

    fbfd = open("/dev/fb0", O_RDWR);
    if (fbfd == -1) { perror("FB"); return 1; }

    struct fb_var_screeninfo vinfo;
    ioctl(fbfd, FBIOGET_VSCREENINFO, &vinfo);
    ioctl(fbfd, FBIOGET_FSCREENINFO, &finfo);

    screensize = (long)vinfo.yres_virtual * finfo.line_length;
    fbp = mmap(NULL, screensize, PROT_READ | PROT_WRITE, MAP_SHARED, fbfd, 0);
    if (fbp == MAP_FAILED) { perror("mmap"); close(fbfd); return 1; }

    // === Выделяем все большие буферы ОДИН РАЗ ===
    background_buffer = malloc(BUFFER_SIZE);
    offscreen_buffer  = malloc(BUFFER_SIZE);
    all_data_buffer   = malloc(BUFFER_SIZE);

    if (!background_buffer || !offscreen_buffer || !all_data_buffer) {
        fprintf(stderr, "Критическая ошибка: не хватает памяти!\n");
        return 1;
    }

    // Загрузка фона
    FILE *bg = fopen("./assets/background.rgb565", "rb");
    if (bg) {
        fread(background_buffer, 1, BUFFER_SIZE, bg);
        fclose(bg);
    }

    // Загрузка анимации
    unsigned char frames[ANIM_FRAMES][ANIM_W * ANIM_H * 2] = {0};
    for (int i = 0; i < ANIM_FRAMES; i++) {
        char fname[64];
        sprintf(fname, "./anim/frame%03d.rgb565", i);
        FILE *f = fopen(fname, "rb");
        if (f) {
            fread(frames[i], 1, ANIM_W*ANIM_H*2, f);
            fclose(f);
        }
    }

    load_all_glyphs();

    pthread_t download_tid;
    pthread_create(&download_tid, NULL, download_thread, NULL);

    printf("=== Дашборд запущен — финальная стабильная версия (один malloc) ===\n");

    while (running) {
        for (int f = 0; f < ANIM_FRAMES && running; f++) {
            memcpy(offscreen_buffer, background_buffer, BUFFER_SIZE);

            // Анимация
            for (int row = 0; row < ANIM_H; row++) {
                uint16_t *dst = (uint16_t*)(offscreen_buffer + ((ANIM_Y + row) * (long)SCREEN_W * 2 + ANIM_X * 2));
                uint16_t *src = (uint16_t*)(frames[f] + row * ANIM_W * 2);
                memcpy(dst, src, ANIM_W * 2);
            }

            update_local_fields_offscreen(offscreen_buffer);

            // Наложение all_data
            if (!offline_mode) {
                unsigned char *safe = NULL;
                pthread_mutex_lock(&buffer_mutex);
                safe = all_data_buffer;
                pthread_mutex_unlock(&buffer_mutex);

                if (safe) overlay_all_data_offscreen(offscreen_buffer, safe);
            }

            // Вывод на экран
            for (int y = 0; y < SCREEN_H; y++) {
                memcpy(fbp + (long)y * finfo.line_length,
                       offscreen_buffer + (long)y * (long)SCREEN_W * 2,
                       (size_t)SCREEN_W * 2);
            }

            usleep(ANIM_DELAY);
        }
    }

    running = 0;
    pthread_join(download_tid, NULL);
    pthread_mutex_destroy(&buffer_mutex);

    free(all_data_buffer);
    free(background_buffer);
    free(offscreen_buffer);

    munmap(fbp, screensize);
    close(fbfd);
    return 0;
}
