import { DataGrid, GridToolbar } from "@mui/x-data-grid";
import React from "react";

interface IProps {}
interface IState {
  pods: any[];
}

class Welcome extends React.Component<IProps, IState> {
  constructor(props: IProps) {
    super(props);
    this.state = {
      pods: [],
    }
  }

  componentDidMount() {
    fetch('/api/pods')
      .then(res => res.json())
      .then(json => {
        this.setState({
          pods: json,
        })
      })
  }

  render() {
    const columns = [
      {
        field: 'namespace',
        headerName: 'Namespace',
        flex: 0.5,
      },
      {
        field: 'name',
        headerName: 'Name',
        flex: 1,
      },
      {
        field: 'status',
        headerName: 'Status',
        flex: 1,
      },
    ]
    const pods = this.state.pods;

    return (
      <div>
        <h1>Hello, World!</h1>
        <div style={{ display: 'flex', height: '500px' }}>
          <div style={{ flexGrow: 1 }}>
            <DataGrid
              columns={columns}
              rows={pods}
              disableSelectionOnClick
              components={{
                Toolbar: GridToolbar,
              }}
              getRowId={(row) => row.name}
              />
          </div>
        </div>
      </div>
    )
  }
}
export default Welcome;
