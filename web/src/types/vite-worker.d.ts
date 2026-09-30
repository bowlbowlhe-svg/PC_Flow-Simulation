// Vite 的 `?worker&inline` 导入：默认导出 Worker 构造函数
declare module '*?worker&inline' {
  const WorkerCtor: { new (): Worker };
  export default WorkerCtor;
}
