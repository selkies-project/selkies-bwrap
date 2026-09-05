/* Minimal WGL test: a window, an OpenGL context, a spinning triangle for a
 * fixed number of frames, then the renderer string and the frame rate.
 *
 * The results go to a file beside the executable as well as to standard
 * output, because Wine gives a console application started without a console
 * one of its own, where the output is lost to whoever launched it. */
#include <windows.h>
#include <GL/gl.h>
#include <stdio.h>
#include <stdlib.h>

static LRESULT CALLBACK proc(HWND w, UINT m, WPARAM wp, LPARAM lp)
{
    if (m == WM_CLOSE) { PostQuitMessage(0); return 0; }
    return DefWindowProc(w, m, wp, lp);
}

int main(int argc, char **argv)
{
    int frames = argc > 1 ? atoi(argv[1]) : 300;
    WNDCLASS wc = {0};
    wc.style = CS_OWNDC;
    wc.lpfnWndProc = proc;
    wc.hInstance = GetModuleHandle(NULL);
    wc.lpszClassName = "wgltri";
    RegisterClass(&wc);
    HWND w = CreateWindow("wgltri", "wgltri", WS_OVERLAPPEDWINDOW | WS_VISIBLE,
                          100, 100, 640, 480, NULL, NULL, wc.hInstance, NULL);
    HDC dc = GetDC(w);
    PIXELFORMATDESCRIPTOR pfd = {0};
    pfd.nSize = sizeof pfd;
    pfd.nVersion = 1;
    pfd.dwFlags = PFD_DRAW_TO_WINDOW | PFD_SUPPORT_OPENGL | PFD_DOUBLEBUFFER;
    pfd.iPixelType = PFD_TYPE_RGBA;
    pfd.cColorBits = 24;
    pfd.cDepthBits = 16;
    int pf = ChoosePixelFormat(dc, &pfd);
    if (!pf || !SetPixelFormat(dc, pf, &pfd)) { fprintf(stderr, "no pixel format\n"); return 1; }
    HGLRC rc = wglCreateContext(dc);
    if (!rc || !wglMakeCurrent(dc, rc)) { fprintf(stderr, "no GL context\n"); return 1; }
    char result[MAX_PATH];
    GetModuleFileName(NULL, result, sizeof result);
    char *dot = strrchr(result, '.');
    if (dot) strcpy(dot, ".txt"); else strcat(result, ".txt");
    FILE *out = fopen(result, "w");
    printf("GL_VENDOR: %s\nGL_RENDERER: %s\nGL_VERSION: %s\n",
           glGetString(GL_VENDOR), glGetString(GL_RENDERER), glGetString(GL_VERSION));
    fflush(stdout);
    if (out)
        fprintf(out, "GL_VENDOR: %s\nGL_RENDERER: %s\nGL_VERSION: %s\n",
                glGetString(GL_VENDOR), glGetString(GL_RENDERER), glGetString(GL_VERSION));
    DWORD t0 = GetTickCount();
    for (int i = 0; i < frames; i++) {
        MSG msg;
        while (PeekMessage(&msg, NULL, 0, 0, PM_REMOVE)) {
            if (msg.message == WM_QUIT) frames = i;
            TranslateMessage(&msg);
            DispatchMessage(&msg);
        }
        glClearColor(0.1f, 0.1f, 0.2f, 1.0f);
        glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);
        glLoadIdentity();
        glRotatef(i * 2.0f, 0, 0, 1);
        glBegin(GL_TRIANGLES);
        glColor3f(1, 0, 0); glVertex2f(-0.6f, -0.5f);
        glColor3f(0, 1, 0); glVertex2f(0.6f, -0.5f);
        glColor3f(0, 0, 1); glVertex2f(0.0f, 0.7f);
        glEnd();
        SwapBuffers(dc);
    }
    DWORD ms = GetTickCount() - t0;
    printf("frames: %d in %lu ms (%.1f FPS)\n", frames, (unsigned long) ms,
           ms ? frames * 1000.0 / ms : 0.0);
    if (out) {
        fprintf(out, "frames: %d in %lu ms (%.1f FPS)\n", frames, (unsigned long) ms,
                ms ? frames * 1000.0 / ms : 0.0);
        fclose(out);
    }
    wglMakeCurrent(NULL, NULL);
    wglDeleteContext(rc);
    ReleaseDC(w, dc);
    DestroyWindow(w);
    return 0;
}
