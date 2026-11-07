#!/usr/bin/env python3
"""Differentially run actual pre/post diagnostic Win32u functions with stubs.
Checks that entry/filter logging preserves returns, server requests, clip state,
and driver dispatch. No Wine process, system pointer, windows, or input.
"""
import pathlib
import subprocess
import sys
import tempfile

before = pathlib.Path(sys.argv[1]).read_text()
after = pathlib.Path(sys.argv[2]).read_text()
def methods(text):
    process = text[text.index('BOOL process_wine_clipcursor('):text.index('/**********************************************************************', text.index('BOOL process_wine_clipcursor('))]
    entry = text[text.index('BOOL WINAPI NtUserClipCursor('):text.index('/**********************************************************************', text.index('BOOL WINAPI NtUserClipCursor('))]
    return process + '\n' + entry
enum = after[after.index('enum idv_capture_diag_once'):after.index('/* IDV_CAPTURE_TRANSPORT_BEGIN')]
harness = r'''
#include <stdio.h>
#include <stdarg.h>
#include <string.h>
typedef int BOOL; typedef unsigned UINT; typedef unsigned DWORD; typedef unsigned HWND;
typedef struct { int left,top,right,bottom; } RECT;
#define WINAPI
#define TRUE 1
#define FALSE 0
#define TRACE(...)
#define WARN(...)
enum { MDT_RAW_DPI, MDT_DEFAULT, SET_CURSOR_NOCLIP=2, SET_CURSOR_CLIP=4, SET_CURSOR_FSCLIP=8 };
struct user_thread_info { int clipping_cursor; unsigned clipping_reset; } info;
static int clipping_cursor, grab_pointer, driverSuccess, fsSuccess, driverCalls, driverReset, serverStatus, serverCalls;
static RECT testClip;
static struct { unsigned flags; RECT clip; } request;
static struct user_thread_info *get_user_thread_info(void) { return &info; }
static RECT get_virtual_screen_rect(unsigned a,unsigned b) { return (RECT){0,0,1000,800}; }
static int InterlockedDecrement(int *v) { return --*v; }
static int InterlockedIncrement(int *v) { return ++*v; }
static unsigned NtGetTickCount(void) { return 2000; }
static BOOL get_clip_cursor(RECT *r,unsigned d,unsigned t) { *r=testClip; return TRUE; }
static void intersect_rect(RECT *dst,const RECT *a,const RECT *b) { RECT r={a->left>b->left?a->left:b->left,a->top>b->top?a->top:b->top,a->right<b->right?a->right:b->right,a->bottom<b->bottom?a->bottom:b->bottom}; *dst=r; }
static BOOL EqualRect(const RECT *a,const RECT *b) { return !memcmp(a,b,sizeof(*a)); }
static BOOL clip_fullscreen_window(HWND w,BOOL reset) { return fsSuccess; }
static BOOL driver(const RECT *r,BOOL reset) { driverCalls++;driverReset=reset?2:(r?1:0);return driverSuccess; }
static struct { BOOL (*pClipCursor)(const RECT*,BOOL); } driverTable={driver}, *user_driver=&driverTable;
static void macdrv_capture_diag_log(unsigned bit,const char *fmt,...) { va_list a;va_start(a,fmt);vfprintf(stderr,fmt,a);fputc('\n',stderr);va_end(a); }
static unsigned get_thread_dpi(void) { return 96; }
static HWND NtUserGetForegroundWindow(void) { return 1; }
static BOOL IsRectEmpty(const RECT *r) { return r->right<=r->left || r->bottom<=r->top; }
static BOOL get_present_rect(HWND w,RECT *r,unsigned dpi) { return FALSE; }
static RECT map_rect_virt_to_raw(RECT r,unsigned dpi) { return r; }
static RECT wine_server_rectangle(RECT r) { return r; }
#define SERVER_START_REQ(name) do { __typeof__(request) *req=&request;
#define SERVER_END_REQ } while(0)
static int wine_server_call(void *req) { serverCalls++; return serverStatus; }
'''
checks = r'''
int main(void) {
 unsigned n=0;
 for(int reset=0;reset<2;reset++)for(int grab=0;grab<2;grab++)for(int desktop=0;desktop<2;desktop++)
 for(int noClip=0;noClip<2;noClip++)for(int was=0;was<2;was++)for(int driverOK=0;driverOK<2;driverOK++)for(int fs=0;fs<2;fs++) {
  info=(struct user_thread_info){was,0};clipping_cursor=was;grab_pointer=grab;driverSuccess=driverOK;fsSuccess=fs;driverCalls=driverReset=0;
  testClip=desktop?(RECT){0,0,1000,800}:(RECT){100,100,500,400};
  int result=process_wine_clipcursor(1,noClip?SET_CURSOR_NOCLIP:SET_CURSOR_CLIP,reset);
  printf("process %u %d %d %d %d %d %u\n",n++,result,driverCalls,driverReset,clipping_cursor,info.clipping_cursor,info.clipping_reset);
 }
 RECT cases[]={{100,100,500,400},{500,100,100,400},{100,100,100,100}};
 for(int i=-1;i<3;i++)for(int status=0;status<2;status++) {
  memset(&request,0,sizeof(request));serverCalls=0;serverStatus=status;
  int result=NtUserClipCursor(i<0?NULL:&cases[i]);
  printf("entry %d %d %d %d %u %d,%d,%d,%d\n",i,status,result,serverCalls,request.flags,request.clip.left,request.clip.top,request.clip.right,request.clip.bottom);
 }
 return 0;
}
'''
with tempfile.TemporaryDirectory(prefix='idv-upper-clip-') as temp:
    root = pathlib.Path(temp)
    results = []
    for name, text in [('before', before), ('after', after)]:
        source = root / (name + '.c')
        source.write_text(harness + enum + methods(text) + checks)
        binary = root / name
        subprocess.run(['clang', '-Werror', str(source), '-o', str(binary)], check=True)
        results.append(subprocess.run([str(binary)], check=True, capture_output=True, text=True))
    assert results[0].stdout == results[1].stdout, 'diagnostic patch changed filter behavior'
    for category in ('cause=reset','cause=grab-disabled','cause=desktop-equal','cause=no-effective-clip','reason=process-clip-driver success=0','reason=process-clip-driver success=1','reason=upper-clip-entry','cause=invalid-rect','reason=upper-clip-server success=0','reason=upper-clip-server success=1'):
        assert category in results[1].stderr, category
    print('PASS: 128 dispatch/filter cases and 8 upper API cases preserve exact pre-patch results and emit early-return classifications')
