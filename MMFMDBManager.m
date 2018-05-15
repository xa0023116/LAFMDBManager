//
//  LAFMDBManager.m
//  MiaoMoreNew
//
//  Created by 刘云梦 on 16/7/5.
//  Copyright © 2016年 cn.miao. All rights reserved.
//

#import "FMDBManager.h"
#import "FMDatabaseAdditions.h"
#import "MCConfig.h"

#define QueueName "LAFMDBManager-Queue"

#define DBPath [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES)[0] stringByAppendingPathComponent:@"LAFMDB.db"]

#define variableGrgument( value , string )                                 \
do                                                                         \
{                                                                          \
    if (value != nil) {                                                    \
        va_list args;                                                      \
        va_start(args, value);                                             \
                                                                           \
        *string = [[NSString alloc] initWithFormat:value arguments:args];  \
                                                                           \
        va_end(args);                                                      \
    }                                                                      \
} while (0)                                                                \

static dispatch_queue_t queue;                                 // 多线程安全
static FMDatabase *fmdb;

static const void * const kDispatchLAQueueSpecificKey = &kDispatchLAQueueSpecificKey;

/// SQLite 类型判断
static inline NSString *sqlType(const char *type) {

    if (strcmp(type, @encode(char)) == 0
        || strcmp(type, @encode(int)) == 0
        || strcmp(type, @encode(short)) == 0
        || strcmp(type, @encode(unsigned char)) == 0
        || strcmp(type, @encode(unsigned int)) == 0
        || strcmp(type, @encode(unsigned short)) == 0
        || strcmp(type, @encode(BOOL)) == 0
        || strcmp(type, @encode(long)) == 0                   // NSInteger
        || strcmp(type, @encode(long long)) == 0
        || strcmp(type, @encode(unsigned long)) == 0
        || strcmp(type, @encode(unsigned long long)) == 0) {
        return @"INTEGER";
    } else if (strcmp(type, @encode(float)) == 0) {
        return @"FLOAT";
    } else if (strcmp(type, @encode(double)) == 0) {
        return @"DOUBLE";
    } else if (strcmp(type, "@\"NSNumber\"") == 0) {
        return @"REAL";
    } else if (strcmp(type, "@\"NSDate\"") == 0) {
        return @"NUMERIC";                                    // 在FDMBReultSet 里面做了相应的修正
    } else if (strcmp(type, "@\"NSString\"") == 0) {
        return @"TEXT";
    }

    return @"TEXT";
}



#pragma mark -
#pragma mark 工具方法
@implementation LAFMDBManager (Util)

/// Object 从字典里面获得值
- (nonnull id) revDictionary: (id _Nonnull) object
                  dictionary: (NSDictionary *_Nonnull) dictionary {
    
    [self runtimeProperty:object property:^(objc_property_t property) {
        NSString *propertyName = [NSString stringWithUTF8String:property_getName(property)];
        [object setValue:dictionary[propertyName] forKey:propertyName];
    }];
    
    return object;
}

- (void) runtimeProperty: (id _Nonnull) object
                property: (void (^ _Nonnull)(objc_property_t _Nonnull property)) property {
    u_int count;
    objc_property_t *propertys = class_copyPropertyList(object_getClass(object), &count);
    
    for (u_int i = 0; i < count; i++) {
        property(propertys[i]);
    }
    
    free(propertys);
}


@end


@interface LAFMDBManager()

/// 查询表是否存在
- (BOOL) tableExists: (NSString *) table
              object: (id) object;

/// 执行SQL  "insert update delete drop" 返回成功失败
- (BOOL) exectueSQLX: (NSString *_Nonnull) sql;

/// 执行SQL "Select" 返回结果集
- (nonnull NSArray *) exectueQueryX: (NSString *_Nullable) tableName
                                sql: (NSString *_Nonnull) sql, ...;

@end


#pragma mark -
#pragma mark 直接操作
@implementation LAFMDBManager (Base)

/// 执行SQL  "insert update delete drop" 返回成功失败
- (BOOL) exectueSQL: (NSString *_Nonnull) sql, ... {
    NSString *execSQL;
    variableGrgument(sql, &execSQL);
    
    return [self exectueSQLX:execSQL];
}

/// 执行SQL "Select" 返回结果集
- (nonnull NSArray *) exectueQuery: (NSString *_Nonnull) tableName
                               sql: (NSString *_Nonnull) sql, ... {
    NSString *execSQL;
    variableGrgument(sql, &execSQL);
    
    return [self exectueQueryX:tableName sql:execSQL];
}

@end


@implementation LAFMDBManager

+ (instancetype) sharedManager {
    static LAFMDBManager *fmdbManager;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        fmdbManager = [[LAFMDBManager alloc] init];
        queue       = dispatch_queue_create(QueueName, DISPATCH_CURRENT_QUEUE_LABEL);
        dispatch_queue_set_specific(queue, kDispatchLAQueueSpecificKey, (__bridge void *)self, NULL);
        
        fmdb = [FMDatabase databaseWithPath:DBPath];
        if ([fmdb open]) {
            NSLog(@"Database Open Success");
        } else {
           NSLog(@"Datebase Open Fail");
        }
    });
        
    return fmdbManager;
}

/// 查询表
- (BOOL) tableExists:(NSString *_Nonnull) table {
    BOOL isExists = false;
    if (fmdb) {
        FMResultSet *result = [fmdb executeQuery:@"SELECT [SQL] FROM SQLITE_MASTER WHERE [TYPE] = 'TABLE' AND LOWER(NAME) = ?", table];
        isExists = [result next];
        [result close];
    }
    
    return isExists;
}

/// 查询表并创建表
- (BOOL) tableExists: (NSString *) table
              object: (id) object {
    if (fmdb) {
        FMResultSet *result = [fmdb executeQuery:@"SELECT [SQL] FROM SQLITE_MASTER WHERE [TYPE] = 'TABLE' AND LOWER(NAME) = ?", table];
        BOOL isExists = [result next];
        [result close];
        if (!isExists) {
            if (object != nil) return [self createTable:table object:object];
            return false;
        }
    }
    
    return false;
}

/// 创建表
- (BOOL) createTable: (NSString *_Nonnull) table
              object: (id _Nonnull) object {
    __block BOOL isSuccess = false;
    
    if (fmdb) {
        __block NSString * sqlPrefix = [NSString stringWithFormat:@" CREATE TABLE %@ ( ", table];
        [self runtimeProperty:object property:^(objc_property_t property) {
            
            sqlPrefix = [sqlPrefix stringByAppendingFormat:@"[%s] %@ ,",
                         property_getName(property),
                         sqlType(property_copyAttributeValue(property, "T")) ];
        }];
        sqlPrefix = [sqlPrefix substringToIndex:sqlPrefix.length - 1];
        sqlPrefix = [sqlPrefix stringByAppendingString:@" ) "];
        
        isSuccess = [fmdb executeUpdate:sqlPrefix];
    }
    
    return isSuccess;
}

/// 插入一个对象
- (BOOL) insertObject: (id) object {
    __block BOOL isSuccess = false;
    if (!object) return isSuccess;
    
    if (fmdb) {
        LAFMDBManager __weak *weakSelf = self;
        
        dispatch_sync(queue, ^{
            NSString *tableName = [NSString stringWithUTF8String:object_getClassName(object)];
            LAFMDBManager __strong *strongSelf = weakSelf;
            if ([strongSelf tableExists:tableName object:object]) {
                __block NSArray *valuesArray   = [NSArray array];
                __block NSString *columnString = [NSString string];
                __block NSString *valuesString = [NSString string];
                
                [self runtimeProperty:object property:^(objc_property_t property) {
                    NSString *propertyName = [NSString stringWithUTF8String:property_getName(property)];
                    // 1.判断 取决于valueForKey 的实现函数 objc_msgSend 对于C 基础类型 int float等 用 id类型 接收会崩溃Bug, 而直接每次都用valueForKey取值 2.判断 从数据库取出来的Null
                    if ([object valueForKey:propertyName] != nil
                        && [object valueForKey:propertyName] != [NSNull null]) {
                        valuesArray  = [valuesArray arrayByAddingObject:[object valueForKey:propertyName]];
                        columnString = [columnString stringByAppendingFormat:@"[%@],", propertyName];
                        valuesString = [valuesString stringByAppendingString:@"?,"];
                    }
                }];
                
                if ([columnString isEqualToString:@""]) {
                    isSuccess = false;
                } else {
                    columnString = [columnString substringToIndex:columnString.length - 1];
                    valuesString = [valuesString substringToIndex:valuesString.length - 1];
                    
                    isSuccess = [fmdb executeUpdate:
                                 [NSString stringWithFormat:@" INSERT INTO %@(%@) VALUES(%@) ", tableName, columnString, valuesString]
                               withArgumentsInArray:valuesArray];
                }
            }
        });
    }
    return isSuccess;
}

/// 更改SQL
- (BOOL) updateSQL: (NSString *) sql, ... {
    NSString *execSQL;
    variableGrgument(sql, &execSQL);
    
    return [self exectueSQLX:execSQL];
}

/// 删除对象
- (BOOL) deleteObject: (id) object {
    __block BOOL isSuccess = false;
    if (!object) return isSuccess;

    if (fmdb) {
        dispatch_sync(queue, ^{
            NSString *tableName    = [NSString stringWithUTF8String:object_getClassName(object)];
            __block NSArray *value = [NSArray array];
            __block NSString * sqlPrefix = [NSString stringWithFormat:@" DELETE FROM %@ WHERE ", tableName];
            
            [self runtimeProperty:object property:^(objc_property_t property) {
                
                NSString *propertyName = [NSString stringWithUTF8String:property_getName(property)];
                if ([object valueForKey:propertyName] != nil
                    && [object valueForKey:propertyName] != [NSNull null]) {
                    value     = [value arrayByAddingObject:[object valueForKey:propertyName]];
                    sqlPrefix = [sqlPrefix stringByAppendingFormat:@" [%@]=? AND ", propertyName];
                }
            }];
        
            sqlPrefix = [sqlPrefix stringByAppendingString:@" 1 = 1 "];
            
            isSuccess = [fmdb executeUpdate:sqlPrefix withArgumentsInArray:value];
        });
    }
    
    return isSuccess;
}

/// 删除表
- (BOOL) deleteTable: (NSString *) table {
    return [self exectueSQL:@" DELETE FROM %@ ", table];
}

/// 删除查询
- (BOOL) deleteSQL:(NSString *) sql, ... {
    NSString *execSQL;
    variableGrgument(sql, &execSQL);
    
    return [self exectueSQLX:execSQL];
}

/// 清除表
- (BOOL) dropTable: (NSString *) table {
    return [self exectueSQL:@" DROP TABLE %@ ", table];
}

/// 查询对象
- (BOOL) selectObject: (id) object {
    __block BOOL isSuccess = false;
    if (!object) return isSuccess;

    if (fmdb) {
        dispatch_sync(queue, ^{
            NSString *tableName    = [NSString stringWithUTF8String:object_getClassName(object)];
            __block NSArray *value = [NSArray array];
            __block NSString * sqlPrefix = [NSString stringWithFormat:@" SELECT count(*) as 'count' FROM %@ WHERE ", tableName];
            
            [self runtimeProperty:object property:^(objc_property_t property) {
                NSString *propertyName = [NSString stringWithUTF8String:property_getName(property)];
                if ([object valueForKey:propertyName] != nil
                    && [object valueForKey:propertyName] != [NSNull null]) {
                    value     = [value arrayByAddingObject:[object valueForKey:propertyName]];
                    sqlPrefix = [sqlPrefix stringByAppendingFormat:@" [%@]=? AND ", propertyName];
                }
            }];
            
            sqlPrefix = [sqlPrefix stringByAppendingString:@" 1 = 1 "];
            
            FMResultSet *resultSet = [fmdb executeQuery:sqlPrefix withArgumentsInArray:value];
            {
                [resultSet next];
                isSuccess = [resultSet intForColumn:@"count"] > 0 ? true : false;
            }
            [resultSet close];
        });
    }
    return isSuccess;
}
/// 查询表，通过条件  返回Object
- (NSArray *) selecteAllObject:(NSString *) table
                     condition:(NSString *) conditin,... {
    NSString *sqlPrefix = [NSString stringWithFormat:@" SELECT * FROM %@ WHERE ", table];

    NSString *executeSQL;
    variableGrgument(conditin, &executeSQL);
 
    sqlPrefix = [sqlPrefix stringByAppendingString:(executeSQL == nil ? @" 1 = 1 " : executeSQL)];
    
    return [self exectueQueryX:table sql:sqlPrefix];
}

/// 查询表，通过SQL语句 返回NSDictionary
- (NSArray *) selecteAll: (NSString *) sql, ... {
    NSString *execSQL;
    variableGrgument(sql, &execSQL);
    
    return [self exectueQueryX:nil sql:execSQL];
}


/// 执行SQL  "insert update delete drop" 返回成功失败
- (BOOL) exectueSQLX: (NSString *_Nonnull) sql {
    __block BOOL isSuccess = false;
    if (fmdb) {
        dispatch_sync(queue, ^{
            isSuccess = [fmdb executeUpdate:sql];
        });
    }
    
    return isSuccess;
}

/// 执行SQL "Select" 返回结果集
- (nonnull NSArray *) exectueQueryX: (NSString *_Nullable) tableName
                                sql: (NSString *_Nonnull) sql, ... {
    __block NSArray *valueArray = [NSArray array];
    if (fmdb) {
        dispatch_sync(queue, ^{
            FMResultSet *resultSet = [fmdb executeQuery:sql];
            {
                while ([resultSet next]) {
                    if (tableName != nil) {
                        id object = [[NSClassFromString(tableName) alloc] init];
                        id valueObject = [self revDictionary:object
                                                  dictionary:resultSet.resultDictionary];
                        
                        if (valueObject != nil) valueArray = [valueArray arrayByAddingObject:valueObject];
                    } else {
                        id valueObject = resultSet.resultDictionary;
                        if (valueObject != nil) valueArray = [valueArray arrayByAddingObject:valueObject];
                    }
                }
            }
            [resultSet close];
        });
    }
    
    return valueArray;
}



@end



#pragma mark -
#pragma mark 批量操作
@implementation LAFMDBManager (BatchOperation)

/// 更改SQL 将符合条件的数据全部更改成当前对象内容（注:根据condition 查出来多条数据将变成批量修改）
- (BOOL) updateObject: (id _Nonnull) object
            condition: (NSString * _Nonnull) condition,... {
    __block BOOL isSuccess = false;
    
    if (fmdb) {
        __block NSString *execSQL;
        variableGrgument(condition, &execSQL);
        
        dispatch_sync(queue, ^{
            __block NSString *sqlPrefix = [NSString stringWithFormat:@" UPDATE %s SET ", object_getClassName(object)];
            __block NSArray *valueArray = [NSArray array];
            
            [self runtimeProperty:object property:^(objc_property_t property) {
                NSString *propertyName = [NSString stringWithUTF8String:property_getName(property)];
                if ([object valueForKey:propertyName] != nil
                    && [object valueForKey:propertyName] != [NSNull null]) {
                    valueArray = [valueArray arrayByAddingObject:[object valueForKey:propertyName]];
                    sqlPrefix  = [sqlPrefix stringByAppendingFormat:@" [%@]=?,", propertyName];
                }
            }];
            
            sqlPrefix = [sqlPrefix substringToIndex:sqlPrefix.length - 1];
            sqlPrefix = [sqlPrefix stringByAppendingFormat:@" WHERE %@", execSQL];
            
            isSuccess = [fmdb executeUpdate:sqlPrefix withArgumentsInArray:valueArray];
        });
    }
    
    return isSuccess;
}

////// 查询所有表数据， 返回所有表的字典数据集
//- (nonnull NSArray *) selecteAllTableObject:(BOOL)isObject {
//    __block NSArray *valueArray = [NSArray array];
//    
//    if (fmdb) {
//        dispatch_sync(queue, ^{
//            // 根据请求参数查询数据
//            FMResultSet *resultSet = [fmdb executeQuery:@"SELECT * FROM sqlite_master where type='table';"];
//            {
//                NSMutableArray *tableNameArray = [NSMutableArray array];
//                // 遍历查询结果
//                while (resultSet.next) {
//                    NSString *tableName = [resultSet stringForColumnIndex:1];
//                    [tableNameArray addObject:tableName];
//                }
//                
//                for (NSString *tableName in tableNameArray) {
//                    FMResultSet *resultSet = [fmdb executeQuery:[NSString stringWithFormat:@"SELECT * FROM %@;",tableName]];
//                    
//                    NSMutableDictionary *result = [NSMutableDictionary dictionary];
//                    NSMutableArray *dataArray   = [NSMutableArray array];
//                    // 遍历查询结果
//                    while (resultSet.next) {
//                        if (isObject){
//                            id object = [[NSClassFromString(tableName) alloc] init];
//                            id valueObject = [self revDictionary:object
//                                                      dictionary:resultSet.resultDictionary];
//                            if (valueObject != nil) [dataArray addObject:valueObject];
//                        } else {
//                            id valueObject = resultSet.resultDictionary;
//                            if (valueObject != nil) [dataArray addObject:valueObject];
//                        }
//                    }
//                    
//                    result[tableName] = dataArray;
//                    valueArray = [valueArray arrayByAddingObject:result];
//                }
//            }
//            [resultSet close];
//        });
//    }
//    return valueArray;
//}
//
@end

#pragma mark -
#pragma mark 事务类

@implementation Transaction

- (Transaction *(^)(BOOL)) executeNext {
    return ^Transaction *(BOOL isNext) {
        if (isNext) return self;
        
        return nil;
    };
}

@end

#pragma mark -
#pragma mark 事务
@implementation LAFMDBManager (Transaction)

/// 事务
- (BOOL) beginTransaction: (BOOL) useDeferred
                withBlock:(void (^ _Nullable )(Transaction * _Nullable __strong * _Nullable transaction)) block {
    __block BOOL isSuccess = false;
    Transaction *transaction = [[Transaction alloc] init];
    useDeferred == true ? [fmdb beginDeferredTransaction] : [fmdb beginTransaction];
    {
        block(&transaction);
        
        if (transaction != nil) {
            if([fmdb commit]) {
                isSuccess = true;
            }
        } else {
            [fmdb rollback];
        }
    }
    return isSuccess;
}

@end


#pragma mark -
#pragma mark 数据迁移 和 表改变 （未完全实现）
@implementation  MMFMDBManager (DataMigration)


/// 修改表名字
- (BOOL) alterRenameTable: (NSString * _Nonnull) tableName
                      new: (NSString * _Nonnull) newTableName {
    return [self exectueSQL:@"ALTER TABLE %@ RENAME TO %@ ", tableName, newTableName];
}

/// 更新Column
- (BOOL) alterChangeColumn: (id _Nonnull) object {
    NSString *tableName = [NSString stringWithUTF8String:object_getClassName(object)];
    BOOL isSuccess = [self beginTransaction:true withBlock:^(Transaction *__strong *transaction) {
        Transaction *tempTransaction = *transaction;
        
        tempTransaction
        .executeNext([self alterRenameTable:tableName new:[NSString stringWithFormat:@"%@_temp",tableName]])
        .executeNext([self createTable:tableName object:object])
        .executeNext([fmdb executeUpdate:@"INSERT INTO %@ SELECT * FROM %@_temp", tableName, tableName])
        .executeNext([fmdb executeUpdate:@"DROP TABLE %@_temp", tableName]);
        
        *transaction = tempTransaction;
    }];
    
    return isSuccess;
}

@end


