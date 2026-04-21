SWIFTC = swiftc
TARGET = swift-dict
SOURCES = main.swift

# 路径和库
INCLUDE_PATH = /usr/include
LIB_PATH = /usr/lib
LIBS = -lsqlite3

$(TARGET): $(SOURCES)
	$(SWIFTC) -o $(TARGET) $(SOURCES) -I $(INCLUDE_PATH) -L $(LIB_PATH) $(LIBS)

.PHONY: clean
clean:
	rm -f $(TARGET)

