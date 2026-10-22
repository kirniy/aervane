#include "SMC.h"
#include <stdio.h>
#include <stdint.h>
int main(void) {
    const char *keys[] = {"TC0C","TC1C","TC2C","TC3C","TCAC","TCBC","TCDX","TCGC","TCMb","TG0D","TG1D","TGDD","TH0A","TH1A","TH1B","Tp01","Tp05","Tp09","Tp0D","Tp0V","Tp0Y","Tp0b","Tp0e","Te05","Te0S","Te09","Te0H","Tg0G","Tg0H","Tg0K","Tg0L","Tg0d","Tg0e","Tg0j","Tg0k","Tm0p","Tm1p","Tm2p","Ts0P","Ts0S","Tg0D","Tg1D","T0XD","T0Zh","T0bf","T3C2","TExo","TMT5","TNyn","TRGp","TVZN","TWCA","TZLg","TfAX","ThCs","ThRA","ThzA","TivL","Tvxh","Tvxx","Tj9C","TjA3","Tjxi","Tk2B","Tkxj","Tkyl","Tlzk","Tmzl","Tqhl","Tqzp","Ttzu","TuDv"};
    zsmc_open();
    for (size_t i=0;i<sizeof(keys)/sizeof(keys[0]);i++){unsigned char b[32];size_t n=0;uint32_t t=0;if(zsmc_read_key_name(keys[i],b,32,&n,&t)==0){printf("%s %08x %zu ",keys[i],t,n);for(size_t j=0;j<n;j++)printf("%02x",b[j]);puts("");}}
    zsmc_close();
}
