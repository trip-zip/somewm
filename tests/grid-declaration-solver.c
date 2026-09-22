/* Solve serialized widget declarations with the production Clay header. */
#include <assert.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#define CLAY_IMPLEMENTATION
#include <clay.h>

#define CAP 4096
typedef struct { int parent; char name[80]; Clay_ElementDeclaration d; } Node;
static Node nodes[CAP];
static int count, errors;
static Clay_ElementId ident(int i) { return Clay_GetElementId((Clay_String){
    .length = (int32_t)strlen(nodes[i].name), .chars = nodes[i].name}); }
static void error(Clay_ErrorData e) {
    fprintf(stderr, "%.*s\n", e.errorText.length, e.errorText.chars); errors++;
}
static int add(int parent, const char *name, Clay_SizingAxis w, Clay_SizingAxis h,
               int dir, int gap, int paint) {
    assert(count < CAP);
    int n = count++;
    nodes[n] = (Node){.parent=parent, .d={.layout={.sizing={w,h},
        .layoutDirection=dir, .childGap=gap}}};
    snprintf(nodes[n].name, sizeof(nodes[n].name), "%s", name);
    if (paint) nodes[n].d.backgroundColor = (Clay_Color){255,0,0,255};
    return n;
}
static void declare(int i) {
    CLAY(ident(i), nodes[i].d) {
        for (int j=i+1; j<count; j++) if (nodes[j].parent == i) declare(j);
    }
}
static Clay_BoundingBox box(int i) { return Clay_GetElementData(ident(i)).boundingBox; }
static void solve(const char *label, float width, float height) {
    Clay_SetLayoutDimensions((Clay_Dimensions){width,height});
    Clay_BeginLayout(); declare(0); Clay_RenderCommandArray cmds = Clay_EndLayout(0);
    assert(!errors);
    printf("CASE %s nodes=%d commands=%d EndLayout=1\n",label,count,cmds.length);
    for (int i=0; i<count; i++) {
        Clay_BoundingBox b=box(i);
        printf("%s parent=%d dir=%d gap=%d sizing=%d:%.6f/%d:%.6f box=%.6f,%.6f %.6fx%.6f\n",
            nodes[i].name,nodes[i].parent,nodes[i].d.layout.layoutDirection,
            nodes[i].d.layout.childGap,nodes[i].d.layout.sizing.width.type,
            nodes[i].d.layout.sizing.width.size.percent,nodes[i].d.layout.sizing.height.type,
            nodes[i].d.layout.sizing.height.size.percent,b.x,b.y,b.width,b.height);
    }
}
#define FIT CLAY_SIZING_FIT(0)
#define GROW CLAY_SIZING_GROW(0)
#define FIX(v) CLAY_SIZING_FIXED(v)
#define PCT(v) CLAY_SIZING_PERCENT(v)
static Clay_SizingAxis axis(char type,float value,float min,float max) {
    switch(type) {
    case 'p': return PCT(value); case 'n': return FIX(value);
    case 'g': return CLAY_SIZING_GROW(min,max); default: return CLAY_SIZING_FIT(min,max);
    }
}
static void read_tree(const char *path) {
    FILE *f=fopen(path,"r"); assert(f); char line[512]; count=0;
    while(fgets(line,sizeof(line),f)) {
        int p,dir,gap,paint; char name[80],wt,ht; float w,wm,wx,h,hm,hx;
        assert(sscanf(line,"%d %79s %d %d %c %f %f %f %c %f %f %f %d",
            &p,name,&dir,&gap,&wt,&w,&wm,&wx,&ht,&h,&hm,&hx,&paint)==13);
        add(p,name,axis(wt,w,wm,wx),axis(ht,h,hm,hx),dir,gap,paint);
        int floating=0, target=-1, parent_point=0, own_point=0, offset=0;
        float x=0,y=0;
        sscanf(line,"%*d %*s %*d %*d %*c %*f %*f %*f %*c %*f %*f %*f %*d %n", &offset);
        int left=0,right=0,top=0,bottom=0;
        int fields=sscanf(line+offset,"%d %d %f %f %d %d %d %d %d %d",
            &floating,&target,&x,&y,&parent_point,&own_point,&left,&right,&top,&bottom);
        if (fields >= 6 && floating) {
            assert(target < count-1);
            nodes[count-1].d.floating=(Clay_FloatingElementConfig){
                .attachTo=target<0 ? CLAY_ATTACH_TO_PARENT : CLAY_ATTACH_TO_ELEMENT_WITH_ID,
                .parentId=target<0 ? 0 : ident(target).id,
                .offset={x,y},.attachPoints={.parent=parent_point,.element=own_point},
                .pointerCaptureMode=CLAY_POINTER_CAPTURE_MODE_PASSTHROUGH};
        }
        if (fields == 10)
            nodes[count-1].d.layout.padding=(Clay_Padding){left,right,top,bottom};
    }
    fclose(f); solve(path,1000,1000);
}
int main(int argc, char **argv) {
    assert(argc == 2);
    uint32_t size = Clay_MinMemorySize();
    void *memory = malloc(size);
    assert(memory);
    assert(Clay_Initialize(Clay_CreateArenaWithCapacityAndMemory(size, memory),
        (Clay_Dimensions){1000,1000}, (Clay_ErrorHandler){error,0}));
    Clay_SetCullingEnabled(false);
    read_tree(argv[1]);
    free(memory);
    return 0;
}
