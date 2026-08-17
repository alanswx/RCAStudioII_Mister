#OBJS specifies which files to compile as part of the project
OBJS = cpu.c debug.c debugscreen.c hardware.c main.c system.c

#OBJ_NAME specifies the name of our exectuable
OBJ_NAME = studio2

#COMPILER_FLAGS specifies the additional compilation options we're using
COMPILER_FLAGS = -Wall -DINCLUDE_DEBUGGING_SUPPORT -DSOUND

ifeq ($(OS),Windows_NT)

#CC specifies which compiler we're using
CC = gcc
#INCLUDE_PATHS specifies the additional include paths we'll need
INCLUDE_PATHS = -IC:\mingw\sdl\include\SDL2 -Iframework -I.
#LIBRARY_PATHS specifies the additional library paths we'll need
LIBRARY_PATHS = -LC:\mingw\sdl\lib
#LINKER_FLAGS specifies the libraries we're linking against
# -Wl,-subsystem,windows gets rid of the console window
LINKER_FLAGS = -lmingw32 -lSDL2main -lSDL2 -static-libgcc -static-libstdc++
COMPILER_FLAGS += -DWINDOWS

else

# Unix (Linux / macOS): let sdl2-config locate SDL2.
CC = cc
SDL_CFLAGS := $(shell sdl2-config --cflags)
SDL_LIBS := $(shell sdl2-config --libs)
ifeq ($(SDL_CFLAGS)$(SDL_LIBS),)
$(error sdl2-config not found - install SDL2 (brew install sdl2 / apt install libsdl2-dev))
endif
INCLUDE_PATHS = $(SDL_CFLAGS) -I.
LIBRARY_PATHS =
LINKER_FLAGS = $(SDL_LIBS)

endif

#The headless build drops SDL entirely: headless.c supplies main() and the IF_* stubs, so the only
#objects needed are the CPU, the system bridge and the front end. Links against libc alone.
HEADLESS_OBJS = cpu.c system.c headless.c
HEADLESS_NAME = studio2_headless

#This is the target that compiles our executable
all : $(OBJS)
	$(CC) $(OBJS) $(INCLUDE_PATHS) $(LIBRARY_PATHS) $(COMPILER_FLAGS) $(LINKER_FLAGS) -o $(OBJ_NAME)

headless : $(HEADLESS_OBJS)
	$(CC) $(HEADLESS_OBJS) -I. -Wall -o $(HEADLESS_NAME)

clean :
	rm -f $(OBJ_NAME) $(OBJ_NAME).exe $(HEADLESS_NAME) $(HEADLESS_NAME).exe

.PHONY : all clean headless
