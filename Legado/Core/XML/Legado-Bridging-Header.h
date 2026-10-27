//
//  Legado-Bridging-Header.h
//  把系统 libxml2 暴露给 Swift，用于 XPath 规则解析（对齐上游 JXDocument 能力）
//

#ifndef Legado_Bridging_Header_h
#define Legado_Bridging_Header_h

#include <libxml/HTMLparser.h>
#include <libxml/HTMLtree.h>
#include <libxml/parser.h>
#include <libxml/tree.h>
#include <libxml/xpath.h>
#include <libxml/xpathInternals.h>

#endif /* Legado_Bridging_Header_h */
