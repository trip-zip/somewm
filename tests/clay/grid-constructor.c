/* Ordinary upstream declarations only. No measurement or second solve.
 * The optional TSV reader also runs the actual Lua compiler output unchanged. */
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
static void near(float a, float b) { if (fabsf(a-b) > .002f) {
    fprintf(stderr,"expected %.6f got %.6f\n",b,a); abort(); } }
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
/* Equal expanded columns; row heights come from real authored minima.
 * Widgets have GROW allocation with intrinsic floors just like the compiler. */
static void regular(int items, int rows, int cols, float width, int hole, int grow) {
    count=0;
    add(-1,"GRID",FIX(width),FIT,CLAY_TOP_TO_BOTTOM,5,0);
    for(int r=0; r<rows; r++) {
        char name[80]; snprintf(name,sizeof(name),"ROW_%d",r);
        int row=add(0,name,GROW,CLAY_SIZING_FIT(20),CLAY_LEFT_TO_RIGHT,5,0);
        for(int c=0; c<cols; c++) {
            snprintf(name,sizeof(name),"CELL_%d_%d",r,c);
            int cell=add(row,name,grow ? CLAY_SIZING_GROW(10) : PCT(1.0f/cols),
                CLAY_SIZING_GROW(20),CLAY_LEFT_TO_RIGHT,0,0);
            if(r*cols+c<items && r*cols+c!=hole) {
                snprintf(name,sizeof(name),"WIDGET_%d",r*cols+c);
                add(cell,name,CLAY_SIZING_GROW(10),CLAY_SIZING_GROW(20),0,0,1);
            }
        }
    }
    char label[80]; snprintf(label,sizeof(label),"regular-%d-%dx%d-width%g-hole%d-%s",items,rows,cols,width,hole,grow?"grow":"percent");
    solve(label,width,200);
    float track=(width-(cols-1)*5)/cols;
    for(int i=1;i<count;i++) if(!strncmp(nodes[i].name,"CELL",4)) {
        int r,c; assert(sscanf(nodes[i].name,"CELL_%d_%d",&r,&c)==2);
        near(box(i).width,track); near(box(i).x,c*(track+5)); near(box(i).y,r*25);
    }
}
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
/* Two diagonal intrinsic minima are sufficient to expose cross-row sharing.
 * Transposition solves column maxima but loses the shared row heights. */
static void content(int transpose, int grow) {
    count=0;
    add(-1,"GRID",FIT,FIT,transpose?CLAY_LEFT_TO_RIGHT:CLAY_TOP_TO_BOTTOM,5,0);
    for(int r=0;r<2;r++) {
        char name[80]; snprintf(name,sizeof(name),"LINE_%d",r);
        int row=add(0,name,grow==2&&!transpose?GROW:FIT,grow==2&&transpose?GROW:FIT,transpose?CLAY_TOP_TO_BOTTOM:CLAY_LEFT_TO_RIGHT,5,0);
        for(int c=0;c<2;c++) {
            int k=transpose ? c*2+r : r*2+c;
            const float widths[]={40,70,20,30}, heights[]={10,20,30,10};
            snprintf(name,sizeof(name),"CONTENT_%d",k);
            add(row,name,grow?CLAY_SIZING_GROW(widths[k]):FIX(widths[k]),
                grow?CLAY_SIZING_GROW(heights[k]):FIX(heights[k]),0,0,1);
        }
    }
    solve(grow==2?(transpose?"content-transposed-grow-columns":"content-grow-rows"):transpose?"content-transposed":grow?"content-grow":"content-fit",400,200);
    printf("UNRESOLVED contract nonhomogeneous=115x55 homogeneous=145x65; actual=%.3fx%.3f\n",box(0).width,box(0).height);
}
/* Smallest homogeneous-content failure: two unequal leaves in one row.
 * Alternative: percentage cells in a FIT row. This loses intrinsic extent,
 * so it cannot supply the missing shared maximum either. */
static void homogeneous_content(int policy) {
    count=0;
    add(-1,"GRID",FIT,FIT,CLAY_TOP_TO_BOTTOM,0,0);
    int row=add(0,"ROW",FIT,FIT,CLAY_LEFT_TO_RIGHT,5,0);
    for(int c=0;c<2;c++) {
        char name[80]; snprintf(name,sizeof(name),"CELL_%d",c);
        int cell=add(row,name,policy==1?PCT(.5f):policy==2?CLAY_SIZING_GROW(70):GROW,GROW,0,0,0);
        snprintf(name,sizeof(name),"WIDGET_%d",c);
        add(cell,name,CLAY_SIZING_GROW(c?70:40),CLAY_SIZING_GROW(10),0,0,1);
    }
    solve(policy==2?"authored-common-floor-70":policy==1?"homogeneous-content-percent-fit":"homogeneous-content-grow-fit",300,100);
    if(policy==2) { near(box(0).width,145); near(box(3).width,70); near(box(5).width,70);
        puts("PASS authored common floor70; does not infer a content maximum"); return; }
    puts("UNRESOLVED homogeneous-content contract: GRID 145x10; WIDGET_0 0,0 70x10; WIDGET_1 75,0 70x10");
}
/* Real cell envelopes carry authored floors through percentage slots.
 * Every declared cell is an actual occupancy allocation, including holes;
 * there is no second tree, duplicate widget or measurement-only element. */
static void floor_envelopes(float width, float height, int rows, int columns,
                            int items, int expand_y) {
    count=0;
    add(-1,"HOST",FIX(width),FIX(height),CLAY_LEFT_TO_RIGHT,0,0);
    int grid=add(0,"GRID",CLAY_SIZING_GROW(10),CLAY_SIZING_GROW(20),CLAY_TOP_TO_BOTTOM,5,0);
    for(int r=0;r<rows;r++) {
        char name[80]; snprintf(name,sizeof(name),"ROW_SLOT_%d",r);
        int row_slot=add(grid,name,GROW,expand_y?PCT(1.0f/rows):FIT,CLAY_LEFT_TO_RIGHT,0,0);
        snprintf(name,sizeof(name),"ROW_%d",r);
        int row=add(row_slot,name,GROW,CLAY_SIZING_GROW(20),CLAY_LEFT_TO_RIGHT,5,0);
        for(int c=0;c<columns;c++) {
            snprintf(name,sizeof(name),"SLOT_%d_%d",r,c);
            int slot=add(row,name,PCT(1.0f/columns),GROW,CLAY_LEFT_TO_RIGHT,0,0);
            snprintf(name,sizeof(name),"CELL_%d_%d",r,c);
            int cell=add(slot,name,CLAY_SIZING_GROW(10),CLAY_SIZING_GROW(20),0,0,0);
            if(r*columns+c<items) {
                snprintf(name,sizeof(name),"WIDGET_%d",r*columns+c);
                add(cell,name,CLAY_SIZING_GROW(10),CLAY_SIZING_GROW(20),0,0,1);
            }
        }
    }
    char label[80]; snprintf(label,sizeof(label),"floor-envelopes-%gx%g-%dx%d-items%d-expandY%d",width,height,rows,columns,items,expand_y);
    solve(label,width,height);
    float expected_width=fmaxf(width,columns*10+(columns-1)*5);
    float expected_height=fmaxf(height,rows*20+(rows-1)*5);
    for(int i=0;i<count;i++) if(!strncmp(nodes[i].name,"CELL_",5)) {
        int r,c; assert(sscanf(nodes[i].name,"CELL_%d_%d",&r,&c)==2);
        near(box(i).width,(expected_width-(columns-1)*5)/columns);
        near(box(i).height,expand_y?(expected_height-(rows-1)*5)/rows:20);
        near(box(i).x,c*(box(i).width+5));
        near(box(i).y,r*(box(i).height+5));
    }
    puts("PASS authored cell floors through actual percentage-slot envelopes");
}

/* Native GROW enclosing FIT rows shares the row's available width, but
 * cannot preserve intrinsic column proportions. Explicit authored shares
 * can do so without measurement; they are an API proposal, not inferred. */
static void expansion_alternatives(int policy) {
    count=0;
    add(-1,"GRID",FIX(225),FIT,CLAY_TOP_TO_BOTTOM,5,0);
    const float widths[]={40,70,20,30};
    for(int r=0;r<2;r++) {
        char name[80]; snprintf(name,sizeof(name),"ROW_%d",r);
        int row=add(0,name,GROW,FIT,0,5,0);
        for(int c=0;c<2;c++) {
            snprintf(name,sizeof(name),"CELL_%d_%d",r,c);
            int cell=add(row,name,policy==1?PCT(c?7.0f/11:4.0f/11):GROW,GROW,0,0,0);
            snprintf(name,sizeof(name),"WIDGET_%d",r*2+c);
            add(cell,name,policy==2?FIX(widths[r*2+c]):CLAY_SIZING_GROW(widths[r*2+c]),CLAY_SIZING_GROW(20),0,0,1);
        }
    }
    solve(policy==1?"authored-shares-4-to-7":policy==2?"grow-envelope-fixed-content":"grow-envelope-grow-content",225,100);
    if(policy==1) {
        near(box(3).width,80);near(box(5).width,140);
        near(box(8).width,80);near(box(10).width,140);
        puts("PASS 80/140 only with genuinely authored 4:7 shares; no content inference");
    }
}

/* Native alignment and another percentage level cannot discard the
 * width-dependent fractional remainder. Same semantic equal-share inputs. */
static void rounding_nested(float width, int align) {
    count=0;add(-1,"HOST",FIX(width),FIX(20),0,0,0);
    int grid=add(0,"GRID",PCT(1),GROW,0,5,0);
    nodes[grid].d.layout.childAlignment.x=align?CLAY_ALIGN_X_CENTER:CLAY_ALIGN_X_LEFT;
    int a=add(grid,"SLOT_A",PCT(.5f),GROW,0,0,0);
    add(a,"A",GROW,GROW,0,0,1);
    int b=add(grid,"SLOT_B",PCT(.5f),GROW,0,0,0);
    add(b,"B",GROW,GROW,0,0,1);
    solve(align?"rounding-nested-center":"rounding-nested-left",width,20);
    near(box(a).width,(width-5)/2);near(box(b).width,(width-5)/2);
    printf("ROUNDING contract floor=%.0f actual=%.3f at width=%.0f\n",floorf((width-5)/2),box(a).width,width);
}
int main(int argc,char **argv) {
    uint32_t size=Clay_MinMemorySize(); void *memory=malloc(size); assert(memory);
    Clay_Initialize(Clay_CreateArenaWithCapacityAndMemory(size,memory),(Clay_Dimensions){1000,1000},(Clay_ErrorHandler){error,0});
    Clay_SetCullingEnabled(false);
    if(argc>1) read_tree(argv[1]); else {
        regular(0,0,3,300,-1,0); regular(0,2,3,300,-1,0);
        regular(1,1,3,300,-1,0); regular(2,1,3,300,-1,0);
        regular(7,3,3,300,-1,0); regular(7,3,3,400,-1,0);
        regular(6,2,3,300,1,0); regular(7,3,3,300,-1,1);
        regular(2,1,2,200,-1,0); regular(2,1,2,200,-1,1);
        puts("UNRESOLVED rounding: both PERCENT and GROW produce 97.5/97.5, contract 97/97 + remainder1");
        content(0,0); content(0,1); content(1,1); content(0,2); content(1,2);
        homogeneous_content(0); homogeneous_content(1); homogeneous_content(2);
        floor_envelopes(25,25,2,3,1,1);
        floor_envelopes(25,25,2,3,0,1);
        floor_envelopes(300,200,3,3,7,0);
        floor_envelopes(300,200,3,3,7,1);
        expansion_alternatives(0); expansion_alternatives(1); expansion_alternatives(2);
        rounding_nested(200,0); rounding_nested(200,1); rounding_nested(201,0);
    }
    free(memory); return 0;
}
