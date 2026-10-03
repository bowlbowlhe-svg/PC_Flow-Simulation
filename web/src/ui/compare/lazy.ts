// 对比展示页的按需加载入口：普通构建拆成单独的块（主包不含预计算数据与对比 Worker）；单文件版仍全部内联。
import data from '../../compare/data.json';
import type { CompareData } from '../../compare/data';

export { ComparePage } from './ComparePage';
export { CompareClient } from '../compareClient';
export const COMPARE_DATA = data as unknown as CompareData;
