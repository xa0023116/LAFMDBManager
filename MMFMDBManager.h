//
//  LAFMDBManager.h
//  MiaoMoreNew
//
//  Created by 刘云梦 on 16/7/5.
//  Copyright © 2016年 cn.miao. All rights reserved.
//

#import <Foundation/Foundation.h>
#import "objc/runtime.h"

@interface LAFMDBManager : NSObject

/**
 *Manager 单例
 */
+ (nonnull instancetype) sharedManager;

/**
 *是否存在表
 *
 *@param tableName 表名
 *
 *@return 是否存在表
 */
- (BOOL) tableExists: (NSString *_Nonnull) tableName;

/// 创建表
- (BOOL) createTable: (NSString *_Nonnull) table
              object: (id _Nonnull) object;


/// insert
/**
 *插入一个对象
 *
 *@param object 任意对象
 *
 *@return 是否Insert成功
 */
- (BOOL) insertObject: (id _Nonnull ) object;


/// Update
/**
 *更改SQL
 *
 *@param sql Update 执行语句
 *
 *@return 是否Update成功
 */
- (BOOL) updateSQL: (NSString *_Nonnull) sql, ...;


/// Delete
/**
 *删除对象 (完全匹配每一个对象属性)
 *
 *@param object 需要删除的对象
 *
 *@return 是否Delete成功
 */
- (BOOL) deleteObject: (id _Nonnull) object;

/**
 *删除表 (如果表不存在，则返回false, 不进行表存在判断)
 *
 *@param tableName 表名
 *
 *@return 是否Delete成功
 */
- (BOOL) deleteTable: (NSString *_Nonnull) tableName;

/**
 *删除SQL
 *
 *@param sql Delete 执行语句
 *
 *@return 是删Delete成功
 */
- (BOOL) deleteSQL: (NSString *_Nonnull) sql, ...;


/// Drop
/**
 *清除表
 *
 *@param  tableName 表明
 *
 *@return 是否Drop成功
 */
- (BOOL) dropTable: (NSString *_Nonnull) tableName;


/// Selected
/**
 *查询对象是否在表中(完全匹配每一个对象属性)
 *
 *@param  object 查询对象
 *
 *@return 表中是否存在这个对象
 */
- (BOOL) selectObject: (id _Nonnull) object;

/**
 *通过查询条件查询表
 *
 *@param  tableName 查询对象
 *@param  conditin  查询条件
 *
 *@return 返回查询到的结果  (table的 Model结果集) [Model(tableName), ...]
 */
- (nonnull NSArray *) selecteAllObject: (NSString *_Nonnull) tableName
                             condition: (NSString *_Nonnull) conditin, ...;

/**
 *通过查询条件查询表
 *
 *@param  sql  查询条件
 *
 *@return 返回查询到的结果  (字典结果集) [{column : value, ...}, ...]
 */
- (nonnull NSArray *) selecteAll: (NSString *_Nonnull) sql, ...;

@end

#pragma mark -
#pragma mark 工具方法
@interface LAFMDBManager (Util)

/// Object 从字典里面获得值
- (nonnull id) revDictionary: (id _Nonnull) object
                  dictionary: (NSDictionary *_Nonnull) dictionary;

/// runtime Property 反射
- (void) runtimeProperty: (id _Nonnull) object
                property: (void (^ _Nonnull)(objc_property_t _Nonnull property)) property;

@end


#pragma mark -
#pragma mark 直接操作
@interface LAFMDBManager (Base)

/**
 *执行SQL "insert update delete drop"
 *
 *@param  sql 查询语句
 *
 *@return 返回查询结果
 */
/// 执行SQL  "insert update delete drop" 返回成功失败
- (BOOL) exectueSQL: (NSString *_Nonnull) sql, ...;


/**
 *执行SQL "Select" 依据talbeName返回Model结果集 如果tableName == nil 则返回 字典的结果集
 * Model结果集 : [Model(tableName), ...]    字典结果集 [{column : value, ...}, ...]
 *
 *@param  tableName 结果集Model对象，如果是View 或者 Sub Query 传nil 返回字典结果集
 *@param  sql       查询语句
 *
 *@return 返回查询到的结果  (table的 Model结果集 或 字典的结果集)
 */
- (nonnull NSArray *) exectueQuery: (NSString *_Nonnull) tableName
                               sql: (NSString *_Nonnull) sql, ...;

@end

#pragma mark -
#pragma mark 批量操作
@interface LAFMDBManager (BatchOperation)

/**
 *更改SQL 将符合条件的数据全部更改成当前对象内容（注:根据condition 查出来多条数据将变成批量修改）
 *
 *@param object 将要修改后的存储值
 *@param condition 修改的条件
 *
 *@return 是否Update成功
 */
- (BOOL) updateObject: (id _Nonnull) object
            condition: (NSString * _Nonnull) condition,...;

///**
// *查询所有表数据， 返回所有表的字典数据集
// *
// *@param  isObject 检测字典中的数据集里 是否有现有Model，如果有则变为现有Model, 如果是false 则不做判断
// *
// *@return 返回查询到的结果  (字典的结果集) 结果集结构  isObject = true : [{table : [Model,...] }, ...],  false : [{table: {column : value}, ...}, ...];
// */
//- (nonnull NSArray *) selecteAllTableObject:(BOOL)isObject;

@end

#pragma mark -
#pragma mark 事务

@interface Transaction : NSObject
/**
 判断当前事务是否执行下去， 当executeNext 执行的语句返回的False 的时候 Transaction 返回空 并且在执行完之后进行事务回滚
 如果Transaction 一直不为nil 则执行提交事务
 
 @param executeNext 需要执行的语句
 */
- (nullable Transaction * _Nullable (^)(BOOL)) executeNext;

@end

@interface LAFMDBManager (Transaction)

/**
 *事务
 *
 *@param  useDeferred 是否使用延迟， 由FMDB提供
 *@param  block       执行事务的回调，返回Transaction的类进行操作
 *
 *@return 事务是否执行成功， 如果返回false 事务将会回滚，所以在Block回调中的操作全部将失败
 */
- (BOOL) beginTransaction: (BOOL) useDeferred
                withBlock:(void (^ _Nullable )(Transaction * _Nullable __strong * _Nullable transaction)) block;

@end

#pragma mark -
#pragma mark 数据迁移 和 表改变 （未完全实现）
@interface LAFMDBManager (DataMigration)


/// 修改表名字
- (BOOL) alterRenameTable: (NSString * _Nonnull) tableName
                      new: (NSString * _Nonnull) newTableName;

/// 更新Column
- (BOOL) alterChangeColumn: (id _Nonnull) object;

@end

